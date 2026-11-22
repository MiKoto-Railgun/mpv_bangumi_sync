local utils = require "src.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local config = require "src.config"
local storage_gate = require "src.core.storage_gate"

local M = {}

local pending_episode_ids = {}

local function is_auto_complete_enabled()
  return config.options and config.options.enable_auto_complete == true
end

local function response_succeeded(res)
  local code = res and tonumber(res.status_code) or 0
  return code ~= nil and code >= 200 and code < 300 and res.detached ~= true
end

local function get_subject_eps(subject)
  local eps = type(subject) == "table" and tonumber(subject.eps) or nil
  if eps and eps > 0 and eps < math.huge and eps == math.floor(eps) then
    return eps
  end
  return nil
end

local function maybe_complete_subject(subject_id, synced_ids, collection_status, subject_eps, callback)
    local done = function(ok) callback(ok == true) end
    if not is_auto_complete_enabled() then done(false) return end

    local function with_collection(cs, seps)
        if tonumber(cs) == 2 then done(false) return end
        local function with_eps(total_eps)
            if total_eps ~= nil and total_eps ~= eps_count then done(false) return end
            bangumi_api.update_user_collection_status(subject_id, 2, function(updated)
                if not response_succeeded(updated) then
                    mp.msg.warn("单集已同步，但番剧自动标记看过失败: " .. tostring(subject_id))
                    done(false) return
                end
                mp.msg.info("番剧全部正片已看，条目状态更新为看过: " .. tostring(subject_id))
                done(true)
            end)
        end
        if seps ~= nil then with_eps(seps) return end
        bangumi_api.get_subject(subject_id, function(subject)
            if not response_succeeded(subject) then done(false) return end
            with_eps(get_subject_eps(subject.body))
        end)
    end

    local eps_count
    local function check_eps(res)
        local body = res and res.body
        if not response_succeeded(res) or type(body) ~= "table" or type(body.data) ~= "table" then
            mp.msg.warn("无法检查番剧是否全部看过: " .. tostring(subject_id))
            done(false) return
        end
        local episodes = body.data
        if #episodes == 0 or tonumber(body.total) ~= #episodes then done(false) return end
        local last_episode, last_sort, seen, all_watched = nil, -math.huge, {}, true
        for _, item in ipairs(episodes) do
            local episode = item.episode
            local id = episode and tonumber(episode.id)
            local sort = episode and tonumber(episode.sort)
            if tonumber(item.type) ~= 2 or not id or seen[id] or not sort or tonumber(episode.type) ~= 0 then
                all_watched = false break
            end
            seen[id] = true
            if sort > last_sort then last_episode, last_sort = id, sort end
        end
        if not all_watched then done(false) return end
        local includes_last = false
        for _, id in ipairs(synced_ids) do
            if tonumber(id) == last_episode then includes_last = true end
        end
        if not includes_last then done(false) return end
        eps_count = #episodes
        if collection_status ~= nil then with_collection(collection_status, subject_eps) return end
        bangumi_api.get_user_collection(subject_id, function(collection)
            if not response_succeeded(collection) or type(collection.body) ~= "table" then done(false) return end
            with_collection(tonumber(collection.body.type), get_subject_eps(collection.body.subject))
        end)
    end
    bangumi_api.get_user_episodes(subject_id, nil, check_eps)
end

local function is_auto_mark_enabled(opts)
  opts = opts or {}
  if opts.auto_mark_enabled ~= nil then
    return opts.auto_mark_enabled == true
  end
  local config_opts = config and config.options or {}
  return config_opts.enable_auto_mark ~= false
end

local function normalize_batch_threshold(value, default_value)
  local threshold = tonumber(value)
  if threshold == nil then
    threshold = default_value or 0
  end
  if threshold < 0 then
    threshold = 0
  end
  return math.floor(threshold)
end

local function resolve_storage_config(opts)
  opts = opts or {}
  if opts.storage and opts.storage.key then
    return opts.storage
  end
  local file_path = mp.get_property("path")
  if file_path then
    file_path = mp.command_native({"normalize-path", file_path})
  end
  return storage_gate.resolve_storage(file_path) or {
    key = "storage1",
    batch_sync_threshold = 1,
  }
end

local function get_storage_threshold(storage_config)
  return normalize_batch_threshold(storage_config and storage_config.batch_sync_threshold, 1)
end

local function get_pending_subject_set(storage_key, subject_id)
  local group = pending_episode_ids[storage_key]
  if not group then
    group = {}
    pending_episode_ids[storage_key] = group
  end
  local set = group[subject_id]
  if not set then
    set = {}
    group[subject_id] = set
  end
  return set
end

local function count_pending(set)
  local count = 0
  for _ in pairs(set or {}) do
    count = count + 1
  end
  return count
end

local function queue_pending_episode(storage_config, subject_id, episode_id, opts, collection_status, subject_eps, callback)
    if not subject_id or not episode_id then callback({queued = false, queued_count = 0, threshold = 0}) return end
    local storage_key = (storage_config and storage_config.key) or "storage1"
    local threshold = get_storage_threshold(storage_config)
    local set = get_pending_subject_set(storage_key, subject_id)
    set[episode_id] = true
    local count = count_pending(set)
    if threshold > 0 and count >= threshold then
        M.flush_pending({
            storage_key = storage_key,
            subject_id = subject_id,
            auto_mark_enabled = opts and opts.auto_mark_enabled,
            collection_status = collection_status,
            subject_eps = subject_eps,
        }, function(results)
            local flushed = results and #results > 0
            callback({
                queued = true, queued_count = count, threshold = threshold,
                flushed = flushed, flush_failed = not flushed, flush_results = results,
                collection_completed = flushed and results[1].collection_completed == true,
            })
        end)
        return
    end
    callback({ queued = true, queued_count = count, threshold = threshold, deferred = true })
end

function M.flush_pending(opts, callback)
    opts = opts or {}
    local done = callback or function() end
    if not is_auto_mark_enabled(opts) and opts.force ~= true then done({}) return end
    local jobs = {}
    for storage_key, subjects in pairs(pending_episode_ids) do
        if not opts.storage_key or opts.storage_key == storage_key then
            for subject_id, set in pairs(subjects) do
                if not opts.subject_id or tonumber(opts.subject_id) == tonumber(subject_id) then
                    local ids = {}
                    for episode_id in pairs(set) do ids[#ids + 1] = episode_id end
                    if #ids > 0 then
                        table.sort(ids)
                        jobs[#jobs + 1] = {
                            storage_key = storage_key, subject_id = subject_id, ids = ids,
                            detach = is_auto_complete_enabled() and false or (opts.detach == true),
                        }
                    end
                end
            end
        end
    end
    local function cleanup()
        for storage_key, subjects in pairs(pending_episode_ids) do
            if not opts.storage_key or opts.storage_key == storage_key then
                if not next(subjects) then pending_episode_ids[storage_key] = nil end
            end
        end
    end
    if #jobs == 0 then cleanup() done({}) return end
    local results, remaining = {}, #jobs
    local function step()
        if remaining == 0 then cleanup() done(results) return end
        local job = table.remove(jobs, 1)
        bangumi_api.update_episodes_status(job.subject_id, job.ids, 2, {
            detach = job.detach,
            callback = function(res)
                remaining = remaining - 1
                local detached_ok = res and res.detached == true
                local succeeded = detached_ok or response_succeeded(res)
                if not succeeded then
                    mp.msg.error("Batch update episode status failed:", job.storage_key, job.subject_id)
                else
                    if pending_episode_ids[job.storage_key] then
                        pending_episode_ids[job.storage_key][job.subject_id] = nil
                    end
                end
                local on_done = function(completed)
                    results[#results + 1] = {
                        storage_key = job.storage_key, subject_id = job.subject_id,
                        count = #job.ids, collection_completed = completed == true,
                    }
                    step()
                end
                if succeeded and not detached_ok then
                    local cs, seps
                    if tonumber(opts.subject_id) == tonumber(job.subject_id) then
                        cs, seps = opts.collection_status, opts.subject_eps
                    end
                    maybe_complete_subject(job.subject_id, job.ids, cs, seps, on_done)
                else
                    on_done(false)
                end
            end,
        })
    end
    step()
end

-- 标记番剧收藏为在看：callback(result)；失败 result.error
function M.mark_bangumi_collection_watching(anime_info, callback)
    local info = anime_info or AnimeInfo
    if not info or not info.bgm_id then
        mp.msg.error("未匹配到Bangumi ID，更新条目失败")
        callback({error = utils.subprocess_err()}) return
    end
    local subject_id = info.bgm_id
    bangumi_api.get_user_collection(subject_id, function(res)
        if not res or not res.body then
            mp.msg.error("获取用户收藏失败")
            callback({error = utils.subprocess_err()}) return
        end
        local status = res.body.type
        local collection_status = response_succeeded(res) and tonumber(status) or nil
        local subject_eps = response_succeeded(res) and get_subject_eps(res.body.subject) or nil
        mp.msg.info("获取用户收藏状态:" .. res.status_code)
        local function respond(msg)
            callback({update_message = msg, collection_status = collection_status, subject_eps = subject_eps})
        end
        local function do_update(label)
            bangumi_api.update_user_collection(subject_id, 3, nil, function(update_res)
                if not response_succeeded(update_res) then
                    mp.msg.error("更新用户收藏失败")
                    callback({error = utils.subprocess_err()}) return
                end
                collection_status = 3
                respond("条目状态更新：" .. label .. " -> 在看")
            end)
        end
        if not status then
            if res.status_code == 404 then do_update("未看") else respond(nil) end
        else
            local update_from = ({"想看", nil, nil, "搁置", "抛弃"})[status]
            if update_from then do_update(update_from) else respond(nil) end
        end
    end)
end

-- 获取剧集列表：callback(result)
function M.prepare_episode_status_update(opts, callback)
    opts = opts or {}
    local subject_id = tonumber(opts.subject_id or (opts.anime_info and opts.anime_info.bgm_id))
    local status = tonumber(opts.status) or 2
    if not subject_id then
        mp.msg.error("缺少Bangumi条目ID，无法准备更新单集状态")
        callback(utils.subprocess_err()) return
    end
    local result = {}
    if status == 2 then
        M.mark_bangumi_collection_watching({bgm_id = subject_id}, function(collection_resp)
            if not collection_resp or collection_resp.error then
                mp.msg.error("收藏状态检测失败，停止更新单集状态")
                callback(utils.subprocess_err()) return
            end
            result.collection_update_message = collection_resp.update_message
            result.collection_updated = collection_resp.update_message ~= nil
            result.collection_status = collection_resp.collection_status
            result.subject_eps = collection_resp.subject_eps
            callback(result)
        end)
        return
    end
    if status == 0 then
        bangumi_api.get_user_collection(subject_id, function(check)
            if check and tonumber(check.status_code or 0) == 404 then
                result.uncollected = true
            elseif not check or tonumber(check.status_code or 0) >= 400 then
                mp.msg.error("收藏状态检测失败，停止更新单集状态")
                callback(utils.subprocess_err()) return
            end
            callback(result)
        end)
        return
    end
    callback(result)
end

-- 获取剧集：callback(result)
M.update_episode = function(opts, callback)
    opts = opts or {}
    local done = callback or function() end
    local batch = opts.batch == true
    local status = tonumber(opts.status) or 2
    if batch and not is_auto_mark_enabled(opts) then done({disabled = true, skipped = true}) return end
    local subject_id = tonumber(opts.subject_id or (opts.anime_info and opts.anime_info.bgm_id))
    local episode_id = tonumber(opts.episode_id)
    local storage_config = resolve_storage_config(opts)
    if not subject_id or not episode_id then
        mp.msg.error("缺少Bangumi条目或剧集ID，更新剧集失败") done(utils.subprocess_err()) return
    end
    M.prepare_episode_status_update({subject_id = subject_id, status = status}, function(collection_resp)
        if not collection_resp then done(utils.subprocess_err()) return end
        if collection_resp.uncollected then done({success = false, uncollected = true}) return end
        local function after_queue(queue_result)
            done({
                success = true,
                deferred = queue_result.deferred == true,
                flushed = queue_result.flushed == true,
                flush_failed = queue_result.flush_failed == true,
                queued_count = queue_result.queued_count,
                batch_sync_threshold = queue_result.threshold,
                storage_key = storage_config and storage_config.key,
                collection_completed = queue_result.collection_completed == true,
                collection_update_message = queue_result.collection_completed and "条目状态更新：看过"
                    or collection_resp.collection_update_message,
                collection_updated = queue_result.collection_completed == true or collection_resp.collection_updated == true,
            })
        end
        if batch and status == 2 then
            queue_pending_episode(storage_config, subject_id, episode_id, opts,
                collection_resp.collection_status, collection_resp.subject_eps, after_queue)
        else
            bangumi_api.update_episode_status(episode_id, status, function(update_res)
                if not response_succeeded(update_res) then
                    mp.msg.error("更新剧集状态失败: " .. tostring(episode_id))
                    done(utils.subprocess_err()) return
                end
                maybe_complete_subject(subject_id, {episode_id},
                    collection_resp.collection_status, collection_resp.subject_eps, function(completed)
                        after_queue({ queued = false, queued_count = 0,
                            threshold = get_storage_threshold(storage_config),
                            collection_completed = status == 2 and completed })
                    end)
            end)
        end
    end)
end

-- 打开URL
function M.open_url(url)
  local platform = mp.get_property_native("platform")
  local cmd
  if platform == "windows" then
    cmd = {"cmd", "/c", "start", "", url}
  elseif platform == "darwin" then
    cmd = {"open", url}
  else
    cmd = {"xdg-open", url}
  end

  return utils.subprocess_wrapper(cmd)
end

-- 搜索番剧

return M
