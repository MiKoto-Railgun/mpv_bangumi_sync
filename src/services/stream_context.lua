local title_guess = require "src.title_guess"
local stream_data = require "src.stream_data"
local sync_context = require "src.services.sync_context"
local bangumi_api = require "src.bangumi_api"
local episode_matcher = require "src.episode_matcher"
local utils = require "src.utils"
local manual_binding = require "src.services.manual_binding"

local M = {}

local SEARCH_LIMIT = 10
local SEARCH_DETAIL_LIMIT = 5

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

local function format_match_failure_reason(title_info, reason)
  if not reason then
    return "原因未知"
  end

  local prefix = string.format(
    "title=%s season=%s episode=%s",
    tostring(title_info and title_info.title),
    tostring(title_info and title_info.season),
    tostring(title_info and title_info.episode_no)
  )
  local code = reason.code
  if code == "NoCandidates" then
    return prefix .. " reason=无候选结果"
  end
  if code == "SeasonFilteredAll" then
    return string.format(
      "%s reason=季度过滤后无候选 parsed_season=%s candidate_count=%s",
      prefix,
      tostring(reason.season),
      tostring(reason.candidate_count)
    )
  end
  if code == "PrimaryExactNotUnique" then
    return string.format("%s reason=name/name_cn 精确命中不唯一 count=%s", prefix, tostring(reason.count))
  end
  if code == "AliasExactNotUnique" then
    return string.format("%s reason=别名精确命中不唯一 count=%s", prefix, tostring(reason.count))
  end
  if code == "NoTitleSimilarity" then
    return string.format(
      "%s reason=候选标题与输入无有效相似度 candidate_count=%s parsed_season=%s",
      prefix,
      tostring(reason.candidate_count),
      tostring(reason.season)
    )
  end
  if code == "FuzzyDisabledShortTitle" then
    return string.format(
      "%s reason=标题过短不启用模糊匹配 best=%s best_score=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score)
    )
  end
  if code == "FuzzyBelowThreshold" then
    return string.format(
      "%s reason=相似度低于阈值 best=%s best_score=%s threshold=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score),
      tostring(reason.threshold)
    )
  end
  if code == "FuzzyGapTooSmall" then
    return string.format(
      "%s reason=最佳候选分差不够 best=%s best_score=%s second=%s second_score=%s gap=%s required_gap=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score),
      tostring(reason.second),
      tostring(reason.second_score),
      tostring(reason.gap),
      tostring(reason.required_gap)
    )
  end
  if code == "SeasonUniqueNotSatisfied" then
    return string.format(
      "%s reason=季度唯一兜底不满足 parsed_season=%s count=%s hit=%s rank=%s rank_limit=%s",
      prefix,
      tostring(reason.season),
      tostring(reason.count),
      tostring(reason.hit),
      tostring(reason.rank),
      tostring(reason.rank_limit)
    )
  end
  return prefix .. " reason=" .. tostring(code)
end

local function resolve_target_episode(episodes, episode_no)
  local match = episode_matcher.match_by_number(episodes, episode_no)
  return match and match.target or nil, match
end

-- fetch_subject：callback(subject 或 nil)
local function fetch_subject(bgm_id, opts, callback)
    bgm_id = tonumber(bgm_id)
    if not bgm_id then callback(nil) return end
    bangumi_api.get_subject(bgm_id, function(res)
        if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
            callback(nil) return
        end
        if not opts or opts.save ~= false then stream_data.save_subject(res.body) end
        callback(res.body)
    end)
end

-- ensure_subject_binding：callback(ok, subject)
local function ensure_subject_binding(title_info, bgm_id, source, callback)
    fetch_subject(bgm_id, {save = false}, function(subject)
        subject = subject or { id = tonumber(bgm_id), name_cn = title_info and title_info.title or nil }
        callback(stream_data.bind_subject(title_info, bgm_id, subject, source), subject)
    end)
end

-- fetch_search_subject：callback(subject 或 nil)
local function fetch_search_subject(item, fetch_detail, search_rank, callback)
    local bgm_id = item and tonumber(item.id)
    if not bgm_id then callback(nil) return end
    if fetch_detail then
        fetch_subject(bgm_id, {save = false}, function(subject)
            if subject then
                subject.search_rank = search_rank
                callback(subject)
            else
                callback({ id = bgm_id, name = item.name, name_cn = item.name_cn, search_rank = search_rank })
            end
        end)
        return
    end
    callback({ id = bgm_id, name = item.name, name_cn = item.name_cn, search_rank = search_rank })
end

-- search_bangumi_subject：callback(bgm_id, source, subject)
-- bgm_id=nil 时 source 标记原因："NoQuery" / "SearchFailed" / "NoMatch" / "SaveFailed"
local function search_bangumi_subject(title_info, callback)
    local query = title_info and title_info.title or nil
    if not query or query == "" then callback(nil, "NoQuery") return end
    mp.msg.verbose("stream_context: 搜索Bangumi条目 " .. tostring(query))
    bangumi_api.search_subjects(query, {limit = SEARCH_LIMIT, type_filter = {2}, callback = function(res)
        if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
            mp.msg.verbose("stream_context: Bangumi搜索失败 " .. tostring(query))
            callback(nil, "SearchFailed") return
        end
        local jobs = {}
        for index, item in ipairs(res.body.data or {}) do
            if #jobs >= SEARCH_LIMIT then break end
            jobs[#jobs + 1] = { item = item, detail = index <= SEARCH_DETAIL_LIMIT, rank = index }
        end
        local subjects_by_rank = {}
        local remaining = #jobs
        local function finish_match()
            local subjects = {}
            for i = 1, SEARCH_LIMIT do
                if subjects_by_rank[i] then subjects[#subjects + 1] = subjects_by_rank[i] end
            end
            local bgm_id, source, score, subject, reason =
                stream_data.match_subject_candidates(title_info, subjects, "search")
            if not bgm_id then
                mp.msg.error("stream_context: Bangumi搜索结果未达到自动绑定阈值 "
                    .. format_match_failure_reason(title_info, reason))
                callback(nil, "NoMatch") return
            end
            mp.msg.info(string.format("流媒体自动匹配Bangumi条目: bgm_id=%s source=%s score=%s",
                tostring(bgm_id), tostring(source), tostring(score)))
            if not stream_data.bind_subject(title_info, bgm_id, subject, source) then
                callback(nil, "SaveFailed") return
            end
            callback(bgm_id, source, subject)
        end
        if remaining == 0 then finish_match() return end
        for _, job in ipairs(jobs) do
            fetch_search_subject(job.item, job.detail, job.rank, function(subject)
                subjects_by_rank[job.rank] = subject   -- 按搜索名次归位，保持确定性顺序
                remaining = remaining - 1
                if remaining == 0 then finish_match() end
            end)
        end
    end})
end

-- resolve_bgm_id：callback(bgm_id, source, subject)
local function resolve_bgm_id(title_info, opts, callback)
    local manual_bgm_id = opts and tonumber(opts.manual_bgm_id) or nil
    if manual_bgm_id then
        ensure_subject_binding(title_info, manual_bgm_id, "manual", function(ok, subject)
            if not ok then callback(nil, "SaveFailed") return end
            callback(manual_bgm_id, "manual", subject)
        end)
        return
    end
    local alias = stream_data.get_alias(title_info)
    if alias and alias.bgm_id then
        callback(tonumber(alias.bgm_id), alias.source or "alias", nil) return
    end
    local cached_id, cached_source = stream_data.match_subject(title_info)
    if cached_id then callback(cached_id, cached_source, nil) return end
    search_bangumi_subject(title_info, function(bgm_id, source, subject)
        if bgm_id then callback(bgm_id, source, subject) return end
        if source == "SaveFailed" then callback(nil, "SaveFailed") return end
        callback(nil, "NeedSubjectSelection")
    end)
end

-- build_context：callback(result)
local function build_context(title_info, bgm_id, bgm_source, subject, opts, callback)
    local binding = opts and opts.manual_binding
    if not title_info.episode_no and not binding then
        callback({ status = "error", error = "EpisodeNumberNotFound",
            reason = "EpisodeFromStreamTitleFailed", title_info = title_info })
        return
    end
    local runtime_episode_id = tonumber(bgm_id) * 10000 + (binding and 0 or title_info.episode_no)
    sync_context.get_user_episodes_cached(runtime_episode_id, bgm_id, {
        force_refresh = opts and opts.force_refresh == true,
        all_types = binding ~= nil,
    }, function(episodes)
        if not episodes or not episodes.data then
            callback({ status = "error", error = "EpisodesError",
                reason = "BangumiEpisodesUnavailable", title_info = title_info })
            return
        end
        local target_ep, match_result
        if binding then
            target_ep, match_result = manual_binding.find_episode(episodes.data, binding)
        else
            target_ep, match_result = resolve_target_episode(episodes.data, title_info.episode_no)
        end
        if not target_ep or not target_ep.episode then
            callback({ status = "error", error = "EpisodeMappingNotFound",
                reason = "BangumiEpisodeNotFound", title_info = title_info })
            return
        end
        local function finish(s)
            s = s or {}
            local anime_title = first_non_empty(s.name_cn, s.name, title_info.title)
            local episode = target_ep.episode
            local episode_title = first_non_empty(episode.name_cn, episode.name,
                "第" .. tostring(title_info.episode_no) .. "话")
            local resolved_ep = tonumber(episode.ep) or title_info.episode_no
            local resolved_sort = tonumber(episode.sort)
            local bgm_url = "https://bgm.tv/subject/" .. tostring(bgm_id)
            local episode_info = {
                episodeId = runtime_episode_id, animeId = bgm_id,
                episodeEp = resolved_ep, episodeSort = resolved_sort,
                episodeMatchMode = match_result and match_result.mode or nil,
                manualEpisode = binding ~= nil,
                animeTitle = anime_title, episodeTitle = episode_title,
                bgmEpisodeId = episode.id, shift = 0.0, stream = true,
            }
            local anime_info = {
                animeTitle = anime_title, bangumiUrl = bgm_url,
                stream = true, streamTitle = title_info.title, streamMatchSource = bgm_source,
            }
            callback({
                status = "ok",
                context = {
                    file_path = mp.get_property("path"),
                    episode_id = runtime_episode_id,
                    episode_info = episode_info,
                    anime_info = anime_info,
                    bgm_id = bgm_id, bgm_url = bgm_url,
                    episodes = episodes,
                    storage = { key = "stream", storages = {}, batch_sync_threshold = 1, matched_storage = "stream" },
                    stream_title_info = title_info,
                },
            })
        end
        if subject then finish(subject) return end
        fetch_subject(bgm_id, nil, finish)
    end)
end

-- sync_context_execute：callback(result)
local function sync_context_execute(opts, callback)
    opts = opts or {}
    local binding = manual_binding.get()
    opts.manual_binding = binding
    local title_info = title_guess.get_current_title_info()
    if binding and (not title_info or not title_info.normalized_title) then
        title_info = {title = binding.title or ("Bangumi " .. tostring(binding.subject_id))}
    end
    if not binding and (not title_info or not title_info.normalized_title) then
        callback({ status = "error", error = "StreamTitleError", reason = "TitleUnavailable" })
        return
    end
    if not title_info.episode_no and not binding then
        callback({ status = "error", error = "EpisodeNumberNotFound",
            reason = "EpisodeFromStreamTitleFailed", title_info = title_info })
        return
    end
    if binding then
        build_context(title_info, binding.subject_id, "manual", nil, opts, callback)
        return
    end
    resolve_bgm_id(title_info, opts, function(bgm_id, bgm_source, subject)
        if not bgm_id then
            if bgm_source == "SaveFailed" then
                callback({ status = "error", error = "StreamBindingError",
                    reason = "SaveFailed", title_info = title_info })
                return
            end
            callback({ status = "select_subject", title_info = title_info, query = title_info.title })
            return
        end
        build_context(title_info, bgm_id, bgm_source, subject, opts, callback)
    end)
end

-- M.sync_context(opts, callback)：result.status ∈ ok / select_subject / error
function M.sync_context(opts, callback)
    sync_context_execute(opts, callback or function() end)
end

-- M.bind_current_subject(bgm_id, callback)：callback(ok, err)
function M.bind_current_subject(bgm_id, callback)
    local done = callback or function() end
    local title_info = title_guess.get_current_title_info()
    if not title_info or not title_info.normalized_title then done(false, "TitleUnavailable") return end
    ensure_subject_binding(title_info, bgm_id, "manual", function(ok)
        done(ok, ok and nil or "SaveFailed")
    end)
end

function M.get_current_title_info()
    return title_guess.get_current_title_info()
end

return M
