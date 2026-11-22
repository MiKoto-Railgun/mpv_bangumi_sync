local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local dandanplay_api = require "src.dandanplay_api"
local video_info = require "src.video_info"
local config = require "src.config"
local json_store = require "src.core.json_store"
local storage_gate = require "src.core.storage_gate"
local episode_matcher = require "src.episode_matcher"
local title_guess = require "src.title_guess"
local title_variants = require "src.title_variants"
local manual_binding = require "src.services.manual_binding"

local M = {}

local INFO_CACHE_MAX_AGE = 3600 * 24
local EPISODES_CACHE_MAX_AGE = 3600 * 4

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil then
      value = tostring(value):match("^%s*(.-)%s*$")
      if value ~= "" then
        return value
      end
    end
  end
  return nil
end

local function get_current_file_path()
  local file_path = mp.get_property("path")
  if not file_path then
    return nil
  end
  return mp.command_native({"normalize-path", file_path})
end

local function build_episode_info_from_anime(anime_info, episode_id)
  if not anime_info or not anime_info.episodes then
    mp.msg.error("anime_info or episodes missing")
    return nil
  end

  for _, episode in ipairs(anime_info.episodes) do
    if tostring(episode.episodeId) == tostring(episode_id) then
      return {
        episodeId = episode.episodeId,
        animeId = anime_info.animeId,
        animeTitle = anime_info.animeTitle,
        episodeTitle = episode.episodeTitle,
        type = anime_info.type,
        typeDescription = anime_info.typeDescription,
        shift = 0.0,
      }
    end
  end
  mp.msg.error("Episode ID not found in anime_info: " .. tostring(episode_id))
  return nil
end

local function get_anime_info_cached(episode_id, anime_id, opts, callback)
    local force_refresh = opts and opts.force_refresh
    local info_path = db.get_path(episode_id, "info")
    local function finish(v) callback(v) end
    if not force_refresh then
        local cached = json_store.read(info_path, {
            max_age = INFO_CACHE_MAX_AGE,
            validate = function(data) return data and data.episodes end,
        })
        if cached then
            mp.msg.verbose(string.format("sync_context: anime_info 缓存命中 episode_id=%s anime_id=%s path=%s",
                tostring(episode_id), tostring(anime_id), info_path))
            finish(cached) return
        end
    end
    mp.msg.verbose(string.format("sync_context: anime_info 缓存未命中 episode_id=%s anime_id=%s refresh=%s",
        tostring(episode_id), tostring(anime_id), tostring(force_refresh == true)))
    dandanplay_api.get_anime_info(anime_id, function(fresh)   -- ← dandanplay_api 异步签名
        if fresh and fresh.episodes then
            json_store.write(info_path, fresh, {atomic = true})
            finish(fresh) return
        end
        mp.msg.error(string.format("Failed to get anime info from API episode_id=%s anime_id=%s",
            tostring(episode_id), tostring(anime_id)))
        finish(nil)
    end)
end

local function get_user_episodes_cached(episode_id, bgm_id, opts, callback)
    if not bgm_id then callback(nil) return end
    local force_refresh = opts and opts.force_refresh
    local all_types = opts and opts.all_types == true
    local episodes_path = db.get_path(episode_id, all_types and "episodes_all" or "episodes")
    local function attach(episodes, on_done)   -- collection 附加也异步化
        if not episodes then on_done(nil) return end
        bangumi_api.get_user_collection(bgm_id, function(collection)
            if collection and tonumber(collection.status_code or 0) == 200 and collection.body then
                episodes.collection = collection.body
            end
            on_done(episodes)
        end)
    end
    if not force_refresh then
        local cached = json_store.read(episodes_path, {
            max_age = EPISODES_CACHE_MAX_AGE,
            validate = function(data) return data and data.data end,
        })
        if cached then attach(cached, callback) return end
    end
    bangumi_api.get_user_episodes(bgm_id, {all_types = all_types}, function(episodes)
        if not episodes or tonumber(episodes.status_code or 0) ~= 200
            or not episodes.body or not episodes.body.data then callback(nil) return end
        json_store.write(episodes_path, episodes.body, {atomic = true})
        attach(episodes.body, callback)
    end)
end

-- 获取匹配信息
local function get_match_info(video_path, prepared_info, callback)
    local info = prepared_info or video_info.get_info(video_path)
    if not info then
        mp.msg.verbose("match: video_info not available")
        mp.msg.error("无法获取视频信息: " .. video_path)
        callback({})
        return
    end
    dandanplay_api.match(info, function(matches)
        matches = matches or {}
        if #matches == 0 then
            mp.msg.verbose("match: no candidates from dandanplay")
            mp.msg.error("未找到匹配: " .. info.filename)
        else
            mp.msg.verbose("match: dandanplay candidates=" .. tostring(#matches))
        end
        callback(matches)
    end)
end

local function format_match_results(matches)
  local match_list = {}
  for _, match in ipairs(matches or {}) do
    table.insert(match_list, {
      episodeId = match.episodeId,
      animeTitle = match.animeTitle,
      episodeTitle = match.episodeTitle,
    })
  end
  return match_list
end

local function split_file_path(path)
  local dir_path = path:match("^(.+)/[^/]+$") or path:match("^(.+)\\[^\\]+$") or ""
  local filename = path:match("([^/\\]+)$") or path
  return dir_path, filename
end

local function append_unique(list, seen, value)
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function collect_title_variants(title)
  local variants = {}
  local seen = {}
  for _, value in ipairs(title_variants.normalized_variants(title) or {}) do
    append_unique(variants, seen, value)
  end
  append_unique(variants, seen, title_guess.normalize_title(title))
  return variants
end

local function normalized_titles_match(left, right)
  local left_variants = collect_title_variants(left)
  local right_variants = collect_title_variants(right)
  for _, a in ipairs(left_variants) do
    for _, b in ipairs(right_variants) do
      if a == b then
        return true
      end
      if #a >= 6 and #b >= 6 and (a:find(b, 1, true) or b:find(a, 1, true)) then
        return true
      end
    end
  end
  return utils.fuzzy_match_title(left or "", right or "") >= 0.72
end

local function filename_matches_title(filename, cached_title)
  local current_info = utils.extract_info_from_filename(filename or "")
  local current_title = current_info and current_info.title or nil
  if not current_title or not cached_title then
    return false
  end
  return normalized_titles_match(current_title, cached_title)
end

local function folder_entry_matches_current(entries, filename)
  local current_info = utils.extract_info_from_filename(filename or "")
  local current_title = current_info and current_info.title or nil
  if not current_title then
    return false
  end
  for cached_filename, _ in pairs(entries or {}) do
    if cached_filename ~= filename then
      local cached_info = utils.extract_info_from_filename(cached_filename or "")
      local cached_title = cached_info and cached_info.title or nil
      if cached_title and normalized_titles_match(current_title, cached_title) then
        return true
      end
    end
  end
  return false
end

local function anime_info_matches_filename(anime_info, filename)
  if not anime_info then
    return false
  end
  local candidates = {
    anime_info.animeTitle,
    anime_info.searchKeyword,
  }
  for _, item in ipairs(anime_info.titles or {}) do
    candidates[#candidates + 1] = item and item.title or nil
  end
  for _, title in ipairs(candidates) do
    if filename_matches_title(filename, title) then
      return true
    end
  end
  return false
end

local function can_use_autoload_source(video_source, sync_state, episode_id)
  if not episode_id then
    return false
  end
  local folder_info = sync_state and sync_state.folder_info or nil
  if folder_entry_matches_current(folder_info and folder_info.entries, video_source.filename) then
    return true
  end

  local episode_info = db.get_episode_info(episode_id)
  if episode_info and filename_matches_title(video_source.filename, episode_info.animeTitle) then
    return true
  end

  local anime_info = json_store.read(db.get_path(episode_id, "info"), {
    max_age = INFO_CACHE_MAX_AGE,
    validate = function(data)
      return data and (data.animeTitle or data.searchKeyword or data.titles)
    end,
  })
  if anime_info_matches_filename(anime_info, video_source.filename) then
    return true
  end

  mp.msg.verbose(
    string.format(
      "sync_context: autoload cache mismatch dir=%s filename=%s episode_id=%s",
      tostring(video_source.dir_path),
      tostring(video_source.filename),
      tostring(episode_id)
    )
  )
  return false
end

local function find_target_episode(episodes, episode_no)
  local match = episode_matcher.match_by_number(episodes, episode_no)
  return match and match.target or nil, match
end

local function get_subject_cached(bgm_id, episode_id, opts, callback)
    if not bgm_id then callback(nil) return end
    local force_refresh = opts and opts.force_refresh
    local info_path = db.get_path(episode_id, "info")
    if not force_refresh then
        local cached = json_store.read(info_path, {
            max_age = INFO_CACHE_MAX_AGE,
            validate = function(data) return data and data.id end,
        })
        if cached then callback(cached) return end
    end
    bangumi_api.get_subject(bgm_id, function(res)
        if not res or not res.body or tonumber(res.status_code or 0) >= 400 then callback(nil) return end
        json_store.write(info_path, res.body, {atomic = true})
        callback(res.body)
    end)
end

local function normalize_search_title(title)
  if not title then
    return nil
  end
  local normalized = tostring(title):match("^%s*(.-)%s*$")
  if not normalized or normalized == "" then
    return nil
  end
  normalized = normalized:lower()
  normalized = normalized:gsub("[%s%p_%-]+", "")
  normalized = normalized:gsub("　", "")
  return normalized ~= "" and normalized or nil
end

local function append_unique_title(list, seen, value)
  value = value and tostring(value):match("^%s*(.-)%s*$") or nil
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function collect_search_titles(anime_info)
  local titles = {}
  local seen = {}

  append_unique_title(titles, seen, anime_info and anime_info.searchKeyword)
  append_unique_title(titles, seen, anime_info and anime_info.animeTitle)

  for _, item in ipairs(anime_info and anime_info.titles or {}) do
    append_unique_title(titles, seen, item and item.title)
  end

  return titles
end

local function bangumi_id_from_online_databases_process(anime_info)
  for _, item in ipairs(anime_info and anime_info.onlineDatabases or {}) do
    local url = item and item.url or nil
    local name = item and item.name or nil
    local lower_name = name and tostring(name):lower() or ""
    if url and (url:find("bgm.tv/subject/", 1, true) or lower_name:find("bangumi", 1, true)) then
      local bgm_id = tonumber(url:match("/subject/(%d+)"))
      if bgm_id then
        return bgm_id, url, "online_databases"
      end
    end
  end
  return nil
end

-- 聚合多查询搜索结果：精确命中优先，index 罚分（查询序+结果序），无精确命中回退模糊最高分
-- 返回 (bgm_id, url, source) 或 nil
local function aggregate_search_results(queries, per_query, normalized_queries)
    local candidates, order = {}, {}
    for qi, results in ipairs(per_query or {}) do
        for rank, item in ipairs(results or {}) do
            local id = tonumber(item.id)
            if id then
                local name = normalize_search_title(item.name)
                local name_cn = normalize_search_title(item.name_cn)
                local exact = (name and normalized_queries[name])
                    or (name_cn and normalized_queries[name_cn]) or false
                local penalty = (qi - 1) + (rank - 1)
                local url = "https://bgm.tv/subject/" .. tostring(id)
                local prev = candidates[id]
                if not prev then
                    candidates[id] = { id = id, url = url, penalty = penalty, exact = exact }
                    order[#order + 1] = id
                elseif exact and not prev.exact then
                    prev.exact, prev.penalty = true, penalty
                elseif exact and penalty < prev.penalty then
                    prev.penalty = penalty
                end
            end
        end
    end
    local exact_list = {}
    for _, id in ipairs(order) do
        if candidates[id].exact then exact_list[#exact_list + 1] = candidates[id] end
    end
    if #exact_list > 0 then
        table.sort(exact_list, function(a, b) return a.penalty < b.penalty end)
        return exact_list[1].id, exact_list[1].url, "search"
    end
    local best_score, best = 0, nil
    for _, id in ipairs(order) do
        local c = candidates[id]
        if c.penalty == 0 and best == nil then best = c end
    end
    if best then return best.id, best.url, "search" end
    return nil
end

-- 多查询搜索：并行发起、按序聚合（保持 index 罚分逻辑）
local function bangumi_id_from_search_process(anime_info, callback)
    local queries = collect_search_titles(anime_info)
    if #queries == 0 then callback(nil) return end
    local normalized_queries = {}
    for _, query in ipairs(queries) do
        local normalized = normalize_search_title(query)
        if normalized then normalized_queries[normalized] = true end
    end
    local per_query, remaining = {}, #queries
    if remaining == 0 then callback(nil) return end
    for i, query in ipairs(queries) do
        bangumi_api.search_subjects(query, {limit = 10, type_filter = {2}, callback = function(res)
            per_query[i] = (res and tonumber(res.status_code or 0) < 400
                and res.body and type(res.body.data) == "table") and res.body.data or nil
            remaining = remaining - 1
            if remaining == 0 then
                callback(aggregate_search_results(queries, per_query, normalized_queries))
            end
        end})
    end
end

local function bangumi_binding_process(anime_info, episode_id, callback)
    if not anime_info then callback(nil) return end
    local bgm_url = anime_info.bangumiUrl
    local bgm_id = bgm_url and tonumber(bgm_url:match("/(%d+)$")) or nil
    if bgm_id then callback(bgm_id, bgm_url, "dandanplay") return end
    local resolved_id, resolved_url, source = bangumi_id_from_online_databases_process(anime_info)
    if resolved_id then
        anime_info.bangumiUrl = resolved_url
        json_store.write(db.get_path(episode_id, "info"), anime_info, {atomic = true})
        callback(resolved_id, resolved_url, source)
        return
    end
    bangumi_id_from_search_process(anime_info, function(search_id, search_url, search_source)
        if search_id then
            anime_info.bangumiUrl = search_url
            json_store.write(db.get_path(episode_id, "info"), anime_info, {atomic = true})
            callback(search_id, search_url, search_source)
        else
            callback(nil)
        end
    end)
end

-- 归一化 sync_context 入参，统一兼容 boolean 和 table 两种调用方式。
-- 返回 sync_opts 表，包含刷新、来源、远端文件和 episodes 加载开关。
local function sync_opts_normalize(opts)
  opts = opts or {}
  local is_table = type(opts) == "table"
  local source = is_table and opts.source or nil
  local force_refresh = opts == true or (is_table and opts.force_refresh)

  return {
    force_refresh = force_refresh,
    force_episode_id = is_table and opts.episode_id or nil,
    force_manual_bgm_id = is_table and tonumber(opts.manual_bgm_id) or nil,
    source = source,
    ensure_episodes = not is_table or opts.ensure_episodes ~= false,
    refresh = force_refresh or source == "manual" or source == "manual_bgm",
    remote_url = is_table and opts.remote_url or nil,
    remote_path_key = is_table and opts.remote_path_key or nil,
    remote_video_info = is_table and opts.remote_video_info or nil,
  }
end

-- 处理当前视频来源，区分本地文件和远端文件并准备 storage 信息。
-- 成功返回 status=ok 的 video_source；失败返回 VideoPathError。
local function video_source_process(sync_opts, callback)
    local remote_url = sync_opts.remote_url
    local remote_video_info = sync_opts.remote_video_info
    local is_remote_file = remote_url ~= nil or remote_video_info ~= nil
    local file_path = sync_opts.remote_path_key or (remote_url and utils.stable_url_key(remote_url))
        or get_current_file_path()

    local function proceed(path_final, info, remote)
        mp.msg.verbose("sync_context: 已获取文件路径")
        local storage_config = remote
            and { key = "network_file", storages = {}, batch_sync_threshold = 1, matched_storage = "network_file" }
            or storage_gate.resolve_storage(path_final)
        if not storage_config then
            mp.msg.info("sync_context: 文件不在配置的存储路径内")
            callback({ status = "error", error = "VideoPathError", reason = "NotInStorage" })
            return
        end
        local dir_path, filename
        if remote then
            dir_path = select(1, split_file_path(path_final))
            filename = info.filename
        else
            dir_path, filename = split_file_path(path_final)
        end
        callback({
            status = "ok", file_path = path_final, dir_path = dir_path, filename = filename,
            storage_config = storage_config, remote_video_info = info, is_remote_file = remote,
        })
    end

    if is_remote_file then
        local function with_info(info)
            if not info then
                mp.msg.verbose("sync_context: 无法获取远端视频信息")
                mp.msg.error("无法获取远端视频信息")
                callback({ status = "error", error = "VideoPathError", reason = "RemoteInfoUnavailable" })
                return
            end
            proceed(file_path, info, true)
        end
        if remote_video_info then with_info(remote_video_info) return end
        video_info.get_url_info_async(remote_url or file_path, with_info)
        return
    end

    -- 本地文件：纯本地检查，保持同步
    local file_info = file_path and mp_utils.file_info(file_path) or nil
    if not file_info or file_info.is_file ~= true then
        mp.msg.verbose("sync_context: 文件路径无效或不是文件")
        mp.msg.error("视频路径无效或不是文件")
        callback({ status = "error", error = "VideoPathError", reason = "InvalidPath" })
        return
    end
    proceed(file_path, nil, false)
end

-- 从 DB 读取当前文件已保存的同步状态，包括文件记录、目录记录和手动 Bangumi 绑定。
-- 返回 sync_state 表，包含 db_record、folder_info、manual_bgm_id 和 episode_id。
local function load_sync_state_from_db(sync_opts, video_source)
  local db_record = db.get({path = video_source.file_path})
  mp.msg.verbose(
    string.format(
      "sync_context: db 记录 dandanplay_id=%s bgm_id=%s",
      tostring(db_record and db_record.dandanplay_id),
      tostring(db_record and db_record.bgm_id)
    )
  )

  local folder_info = video_source.dir_path ~= "" and db.get_folder_info(video_source.dir_path) or nil
  local binding = not sync_opts.force_episode_id and manual_binding.get() or nil
  local manual_bgm_id = binding and binding.subject_id or sync_opts.force_manual_bgm_id
  if not manual_bgm_id and folder_info and folder_info.manual and folder_info.bgm_id then
    manual_bgm_id = tonumber(folder_info.bgm_id)
  end

  return {
    db_record = db_record,
    folder_info = folder_info,
    manual_bgm_id = manual_bgm_id,
    manual_binding = binding,
    episode_id = sync_opts.force_episode_id or (db_record and db_record.dandanplay_id),
  }
end

-- 优先使用当前视频的单集绑定，旧的目录绑定仍通过文件名集数匹配。
-- 不适用时 callback(nil)；成功 callback(完整 context)；失败 callback(对应 error)。
local function manual_bangumi_context_process(sync_opts, video_source, sync_state, callback)
    local manual_bgm_id = sync_state.manual_bgm_id
    if not manual_bgm_id or sync_opts.force_episode_id then
        callback(nil)
        return
    end
    local file_info = utils.extract_info_from_filename(video_source.filename or "")
    local binding = sync_state.manual_binding
    local episode_no = binding and (tonumber(binding.episode.ep) or tonumber(binding.episode.sort) or 0)
        or (file_info and file_info.episode or nil)
    if not episode_no then
        mp.msg.error("无法从文件名解析集数: " .. tostring(video_source.filename))
        callback({ status = "error", error = "EpisodeNumberNotFound", reason = "EpisodeFromFilenameFailed" })
        return
    end
    local runtime_episode_id = manual_bgm_id * 10000 + (binding and 0 or episode_no)
    get_user_episodes_cached(runtime_episode_id, manual_bgm_id, {
        force_refresh = sync_opts.refresh,
        all_types = binding ~= nil,
    }, function(episodes)
        if not episodes or not episodes.data then
            mp.msg.error("获取Bangumi剧集列表失败: " .. tostring(manual_bgm_id))
            callback({ status = "error", error = "EpisodesError", reason = "BangumiEpisodesUnavailable" })
            return
        end
        local target_ep, match_result
        if binding then
            target_ep, match_result = manual_binding.find_episode(episodes.data, binding)
        else
            target_ep, match_result = find_target_episode(episodes.data, episode_no)
        end
        if not target_ep then
            local stats = match_result and match_result.stats or {}
            mp.msg.error(string.format(
                "无法在Bangumi剧集中定位当前集: parsed_no=%s max_main_ep=%s mode=%s reason=%s",
                tostring(episode_no), tostring(stats and stats.max_main_ep),
                tostring(match_result and match_result.mode), tostring(match_result and match_result.reason)))
            callback({ status = "error", error = "EpisodeMappingNotFound", reason = "BangumiEpisodeNotFound" })
            return
        end
        mp.msg.verbose(string.format(
            "sync_context: manual_bgm 匹配命中 mode=%s reason=%s parsed_no=%s max_main_ep=%s",
            tostring(match_result and match_result.mode), tostring(match_result and match_result.reason),
            tostring(episode_no), tostring(match_result and match_result.stats and match_result.stats.max_main_ep)))
        if match_result and match_result.reason == "sort_fallback_parsed_gt_max_ep" then
            mp.msg.verbose("sync_context: 检测到累计编号映射，已使用 sort 兜底")
        end
        get_subject_cached(manual_bgm_id, runtime_episode_id,
            {force_refresh = sync_opts.refresh}, function(subject)
            subject = subject or {}
            local anime_title = first_non_empty(subject.name_cn, subject.name,
                "Bangumi " .. tostring(manual_bgm_id))
            local episode_title = first_non_empty(
                target_ep.episode and target_ep.episode.name_cn,
                target_ep.episode and target_ep.episode.name,
                "第" .. tostring(episode_no) .. "话")
            local resolved_ep = target_ep.episode and tonumber(target_ep.episode.ep) or episode_no
            local resolved_sort = target_ep.episode and tonumber(target_ep.episode.sort) or nil
            local episode_info = {
                episodeId = runtime_episode_id,
                animeId = manual_bgm_id,
                episodeEp = resolved_ep,
                episodeSort = resolved_sort,
                episodeMatchMode = match_result and match_result.mode or nil,
                manualEpisode = binding ~= nil,
                animeTitle = anime_title,
                episodeTitle = episode_title,
                bgmEpisodeId = target_ep.episode and target_ep.episode.id or nil,
                shift = 0.0,
            }
            local anime_info = {
                animeTitle = anime_title,
                bangumiUrl = "https://bgm.tv/subject/" .. tostring(manual_bgm_id),
            }
            db.set_bgm_id(video_source.file_path, manual_bgm_id)
            if not binding then
                db.set_episode_info(runtime_episode_id, episode_info)
            end
            callback(sync_context_build(
                video_source, runtime_episode_id, episode_info, anime_info,
                manual_bgm_id, "https://bgm.tv/subject/" .. tostring(manual_bgm_id), episodes))
        end)
    end)
end

-- 组装 sync_context 的统一成功结果。
-- 返回 status=ok，并在 context 中携带文件、剧集、Bangumi、episodes 和 storage 信息。
local function sync_context_build(video_source, episode_id, episode_info, anime_info, bgm_id, bgm_url, episodes)
  return {
    status = "ok",
    context = {
      file_path = video_source.file_path,
      episode_id = episode_id,
      episode_info = episode_info,
      anime_info = anime_info,
      bgm_id = bgm_id,
      bgm_url = bgm_url or (bgm_id and ("https://bgm.tv/subject/" .. tostring(bgm_id)) or nil),
      episodes = episodes,
      storage = video_source.storage_config,
    },
  }
end

-- 优先使用当前视频的单集绑定，旧的目录绑定仍通过文件名集数匹配。
-- 不适用时返回 nil；成功返回完整 context；失败返回对应 error。
local function episode_info_ensure_or_rebuild(sync_opts, video_source, episode_id, episode_info, callback)
    local anime_info = nil
    local function finish()
        if not episode_info then
            mp.msg.error("Episode info not available: " .. tostring(episode_id))
            mp.msg.verbose("sync_context: 查询 anime_info 后仍缺少 episode_info")
            callback({status = "error", error = "EpisodeInfoError", episode_id = episode_id})
            return
        end
        db.set_dandanplay_id(video_source.file_path, episode_id)
        callback({status = "ok", episode_info = episode_info, anime_info = anime_info})
    end
    if episode_info then finish() return end
    local anime_id = math.floor(episode_id / 10000)
    get_anime_info_cached(episode_id, anime_id, {force_refresh = sync_opts.refresh}, function(fetched)
        anime_info = fetched
        episode_info = build_episode_info_from_anime(anime_info, episode_id)
        if episode_info then
            mp.msg.verbose("sync_context: 已从 anime_info 构建 episode_info")
            db.set_episode_info(episode_id, episode_info)
        end
        finish()
    end)
end

-- 处理 dandanplay episode_id 获取流程，包括强制 ID、自动加载和候选匹配。
-- 成功返回 episode_id/episode_info；多候选返回 select；失败返回 MatchNotFound。
local function dandanplay_context_process(sync_opts, video_source, sync_state, callback)
    local episode_id = sync_state.episode_id
    local episode_info = nil
    local episode_source = episode_id and "db" or nil
    if sync_opts.force_episode_id then
        mp.msg.verbose("sync_context: 强制 episode_id=" .. tostring(sync_opts.force_episode_id))
        db.set_dandanplay_id(video_source.file_path, sync_opts.force_episode_id)
        episode_source = "force"
    end
    if not episode_id and not sync_state.skip_autoload then
        local autoload_id = (not video_source.is_remote_file)
            and db.get_autoload_source(video_source.dir_path, video_source.filename) or nil
        if autoload_id then
            if can_use_autoload_source(video_source, sync_state, autoload_id) then
                mp.msg.verbose("sync_context: autoload episode_id=" .. tostring(autoload_id))
                episode_id = autoload_id
                episode_source = "autoload"
            else
                mp.msg.verbose("sync_context: autoload skipped, fallback to dandanplay match")
            end
        else
            mp.msg.verbose("sync_context: 自动加载episode_id失败")
        end
    end
    if episode_id then
        mp.msg.verbose("sync_context: 当前 episode_id=" .. tostring(episode_id))
        episode_info = db.get_episode_info(episode_id)
        if episode_info then mp.msg.verbose("sync_context: episode_info 缓存命中") end
    end

    local function finish_ok(ep_id, ep_info, source)
        if sync_opts.source == "manual" then
            local anime_id = math.floor(ep_id / 10000)
            db.set_manual_selection(video_source.file_path, anime_id)
            mp.msg.verbose("sync_context: 已保存手动 anime_id=" .. tostring(anime_id))
        end
        callback({ status = "ok", episode_id = ep_id, episode_info = ep_info, episode_source = source })
    end

    if episode_id then finish_ok(episode_id, episode_info, episode_source) return end

    get_match_info(video_source.file_path, video_source.remote_video_info, function(matches)
        mp.msg.verbose("sync_context: 匹配候选数=" .. tostring(#matches))
        if #matches > 1 then
            local folder_info = sync_state.folder_info
            if (not video_source.is_remote_file) and folder_info and folder_info.manual and folder_info.anime_id then
                for _, match in ipairs(matches) do
                    if math.floor(match.episodeId / 10000) == folder_info.anime_id then
                        mp.msg.verbose("sync_context: 通过手动 anime_id 自动选择匹配=" .. tostring(folder_info.anime_id))
                        episode_info = match
                        episode_id = match.episodeId
                        episode_source = "match"
                        db.set_dandanplay_id(video_source.file_path, episode_id)
                        db.set_episode_info(episode_id, episode_info)
                        break
                    end
                end
                if not episode_id then mp.msg.verbose("sync_context: 候选中未找到手动 anime_id") end
            end
            if not episode_id then
                local info = utils.extract_info_from_filename(video_source.filename)
                mp.msg.verbose("sync_context: 匹配结果需要手动选择")
                callback({ status = "select", info = info, matches = format_match_results(matches) })
                return
            end
        end
        if not episode_id then
            episode_info = matches[1]
            if episode_info then
                mp.msg.verbose("sync_context: 选中匹配 episode_id=" .. tostring(episode_info.episodeId))
                episode_id = episode_info.episodeId
                episode_source = "match"
                db.set_dandanplay_id(video_source.file_path, episode_id)
                db.set_episode_info(episode_id, episode_info)
            end
        end
        if not episode_id then
            mp.msg.error("Match failed: " .. video_source.file_path)
            mp.msg.verbose("sync_context: 匹配后仍未获得 episode_id")
            callback({ status = "error", error = "MatchNotFound", video = video_source.file_path })
            return
        end
        finish_ok(episode_id, episode_info, episode_source)
    end)
end

-- 处理 Bangumi 绑定和用户 episodes 加载。
-- 成功返回 anime_info、bgm_id、bgm_url、episodes；失败返回 AnimeInfoError。
local function bangumi_context_process(sync_opts, video_source, episode_id, anime_info, callback)
    local function with_anime_info(info)
        anime_info = info
        if not anime_info then
            mp.msg.error("Anime info not available: " .. tostring(episode_id))
            mp.msg.verbose("sync_context: anime_info 缺失或无 bangumiUrl")
            callback({ status = "error", error = "AnimeInfoError", reason = "AnimeInfoMissing",
                episode_id = episode_id })
            return
        end
        bangumi_binding_process(anime_info, episode_id, function(bgm_id, bgm_url, bgm_source)
            mp.msg.verbose(string.format("sync_context: 解析 bgm_id=%s source=%s",
                tostring(bgm_id), tostring(bgm_source)))
            if not bgm_id then
                mp.msg.error(string.format(
                    "Bangumi URL missing in anime info: episode_id=%s anime_id=%s",
                    tostring(episode_id), tostring(anime_info and anime_info.animeId)))
                mp.msg.verbose("sync_context: bangumiUrl 缺失，且 Bangumi 条目回退解析失败")
                callback({ status = "error", error = "AnimeInfoError", reason = "BangumiUrlMissing",
                    episode_id = episode_id })
                return
            end
            db.set_bgm_id(video_source.file_path, bgm_id)
            if not sync_opts.ensure_episodes then
                callback({ status = "ok", anime_info = anime_info, bgm_id = bgm_id,
                    bgm_url = bgm_url, episodes = nil })
                return
            end
            get_user_episodes_cached(episode_id, bgm_id, {force_refresh = sync_opts.refresh}, function(episodes)
                mp.msg.verbose("sync_context: episodes 已加载=" .. tostring(episodes ~= nil))
                callback({ status = "ok", anime_info = anime_info, bgm_id = bgm_id,
                    bgm_url = bgm_url, episodes = episodes })
            end)
        end)
    end
    if anime_info then with_anime_info(anime_info) return end
    local anime_id = math.floor(episode_id / 10000)
    get_anime_info_cached(episode_id, anime_id, {force_refresh = sync_opts.refresh}, with_anime_info)
end

-- sync_context 主编排函数，按来源、状态、匹配、Bangumi 的顺序串联各阶段。
-- 返回 status=ok/select/error，保持 M.sync_context 和 M.match 的对外契约。
local function sync_context_execute(opts, callback)
    local sync_opts = sync_opts_normalize(opts)
    video_source_process(sync_opts, function(video_source)
        if video_source.status ~= "ok" then callback(video_source) return end
        local sync_state = load_sync_state_from_db(sync_opts, video_source)  -- 纯本地，保持同步
        manual_bangumi_context_process(sync_opts, video_source, sync_state, function(manual_result)
            if manual_result then callback(manual_result) return end
            dandanplay_context_process(sync_opts, video_source, sync_state, function(dandanplay_result)
                if dandanplay_result.status ~= "ok" then callback(dandanplay_result) return end
                episode_info_ensure_or_rebuild(sync_opts, video_source,
                    dandanplay_result.episode_id, dandanplay_result.episode_info, function(episode_result)
                    if episode_result.status ~= "ok"
                        and dandanplay_result.episode_source ~= "match"
                        and dandanplay_result.episode_source ~= "force" then
                        -- 原"缓存 episode_id 失效 → 跳过 autoload 重跑匹配"回退链，同样回调串联
                        sync_state.episode_id = nil
                        sync_state.skip_autoload = true
                        dandanplay_context_process(sync_opts, video_source, sync_state, function(retry)
                            if retry.status ~= "ok" then callback(retry) return end
                            episode_info_ensure_or_rebuild(sync_opts, video_source,
                                retry.episode_id, retry.episode_info, function(retry_ep)
                                if retry_ep.status ~= "ok" then callback(retry_ep) return end
                                bangumi_context_process(sync_opts, video_source,
                                    retry.episode_id, retry_ep.anime_info, function(bangumi_result)
                                    if bangumi_result.status ~= "ok" then callback(bangumi_result) return end
                                    callback(sync_context_build(video_source, retry.episode_id,
                                        retry_ep.episode_info, bangumi_result.anime_info,
                                        bangumi_result.bgm_id, bangumi_result.bgm_url, bangumi_result.episodes))
                                end)
                            end)
                        end)
                        return
                    end
                    if episode_result.status ~= "ok" then callback(episode_result) return end
                    bangumi_context_process(sync_opts, video_source,
                        dandanplay_result.episode_id, episode_result.anime_info, function(bangumi_result)
                        if bangumi_result.status ~= "ok" then callback(bangumi_result) return end
                        callback(sync_context_build(video_source, dandanplay_result.episode_id,
                            episode_result.episode_info, bangumi_result.anime_info,
                            bangumi_result.bgm_id, bangumi_result.bgm_url, bangumi_result.episodes))
                    end)
                end)
            end)
        end)
    end)
end

function M.sync_context(opts, callback)
    sync_context_execute(opts, callback or function() end)
end

-- 匹配视频（force_id可选）
function M.match(force_id, callback)
    callback = callback or function() end
    local opts = { episode_id = force_id, ensure_episodes = false,
        source = force_id and "manual" or "auto" }
    sync_context_execute(opts, function(result)
        if not result then callback(nil) return end
        if result.status == "select" then
            callback({info = result.info, matches = result.matches}) return
        end
        if result.status == "ok" and result.context and result.context.episode_info then
            local episode_info = result.context.episode_info
            callback({ info = episode_info, desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle })
            return
        end
        callback(nil)
    end)
end


-- 打开URL

M.construct_episode_match = function(episode_id, opts, callback)
    local anime_id = math.floor(episode_id / 10000)
    get_anime_info_cached(episode_id, anime_id, opts, function(anime_info)
        callback(anime_info and build_episode_info_from_anime(anime_info, episode_id) or nil)
    end)
end
M.get_anime_info_cached = get_anime_info_cached    -- 新签名：(episode_id, anime_id, opts, callback)
M.get_user_episodes_cached = get_user_episodes_cached  -- 新签名：(episode_id, bgm_id, opts, callback)

return M
