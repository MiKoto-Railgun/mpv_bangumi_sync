-- mpv --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/auto_complete.lua
-- All API requests are mocked; no real account data is changed.
local host = require "mp"
local count = 0
package.path = "./?.lua;" .. package.path
local function check(value, message)
  assert(value, message)
  count = count + 1
end

local function run()
  for _, path in ipairs({"src/config.lua", "src/bangumi_api.lua", "src/services/bangumi_service.lua", "main.lua"}) do
    check(loadfile(path), "syntax: " .. path)
  end
  local changed
  package.loaded["mp.options"] = {read_options = function(_, _, callback) changed = callback end}
  local config = require "src.config"
  check(config.options.enable_auto_complete == false, "option defaults to off")
  for value, expected in pairs({yes = true, no = false, invalid = false}) do
    config.options.enable_auto_complete = value
    changed()
    check(config.options.enable_auto_complete == expected, "normalize: " .. value)
  end

  package.loaded["src.paths"] = {DATA_PATH = "."}
  package.loaded["src.http"] = {}
  local api = require "src.bangumi_api"
  local request
  api.patch = function(uri, data)
    request = {uri = uri, data = data}
    return {status_code = 204}
  end
  api.update_user_collection_status(42, 2)
  check(request.uri == "/v0/users/-/collections/42", "patch the correct subject")
  local fields = 0
  for _ in pairs(request.data) do fields = fields + 1 end
  check(fields == 1 and request.data.type == 2, "only send type; preserve privacy, rating, tags and comment")

  package.loaded["src.utils"] = {subprocess_err = function() return {execute = function() return nil end} end}
  package.loaded["src.db"] = {}
  package.loaded["src.services.sync_context"] = {}
  package.loaded["src.episode_matcher"] = {}
  package.loaded["src.core.storage_gate"] = {}

  local service, episodes, total, expected_eps, collection_type
  local episode_code, list_code, subject_code, collection_code, complete_code
  local completions, reads, trace, detached, direct_calls, batch_calls
  local collection_reads, watching_updates, watching_code
  local collection_subject, subject_reads
  local function reset(enabled)
    config.options.enable_auto_complete = enabled
    config.options.enable_auto_mark = true
    episodes = {
      {type = 2, episode = {id = 900, type = 0, sort = 11}},
      {type = 0, episode = {id = 100, type = 0, sort = 12}},
    }
    total, expected_eps, collection_type = 2, 2, 3
    episode_code, list_code, subject_code, collection_code, complete_code = 204, 200, 200, 200, 204
    completions, reads, trace, detached, direct_calls, batch_calls = 0, 0, {}, nil, 0, 0
    collection_reads, watching_updates, watching_code = 0, 0, 204
    collection_subject, subject_reads = {id = 42, eps = 2}, 0
    package.loaded["src.services.bangumi_service"] = nil
    service = require "src.services.bangumi_service"
  end
  local function mark_remote(ids, status)
    if episode_code < 200 or episode_code >= 300 then return end
    for _, item in ipairs(episodes) do
      for _, id in ipairs(ids) do
        if item.episode.id == id then item.type = status end
      end
    end
  end
  api.get_user_collection = function()
    collection_reads = collection_reads + 1
    return {status_code = collection_code, body = {
      type = collection_type, private = true, rate = 9, subject = collection_subject,
    }}
  end
  api.update_user_collection = function(id, status)
    check(id == 42 and status == 3, "prepare watching before episode update")
    watching_updates = watching_updates + 1
    if watching_code == 204 then collection_type, collection_code = 3, 200 end
    return {status_code = watching_code}
  end
  api.get_user_episodes = function(_, opts)
    check(not opts or not opts.all_types, "completion uses main episodes")
    reads = reads + 1
    trace[#trace + 1] = "read"
    return {status_code = list_code, body = {data = episodes, total = total}}
  end
  api.get_subject = function()
    subject_reads = subject_reads + 1
    return {status_code = subject_code, body = {eps = expected_eps}}
  end
  api.update_episode_status = function(id, status)
    direct_calls = direct_calls + 1
    trace[#trace + 1] = "write"
    mark_remote({id}, status)
    return {status_code = episode_code}
  end
  api.update_episodes_status = function(_, ids, status, opts)
    batch_calls = batch_calls + 1
    detached = opts.detach
    trace[#trace + 1] = "write"
    if detached then return {detached = true, status_code = 0} end
    mark_remote(ids, status)
    return {status_code = episode_code}
  end
  api.update_user_collection_status = function(id, status)
    check(id == 42 and status == 2, "mark the synced subject watched")
    completions = completions + 1
    trace[#trace + 1] = "complete"
    if complete_code == 204 then collection_type = 2 end
    return {status_code = complete_code}
  end
  local function update(id, opts)
    opts = opts or {}
    opts.subject_id, opts.episode_id = 42, id
    opts.storage = {key = opts.group or "storage1", batch_sync_threshold = opts.threshold or 1}
    return service.update_episode(opts).execute()
  end

  reset(false)
  update(100)
  check(completions == 0 and reads == 0, "disabled adds no completion requests")
  reset(true)
  local result = update(100)
  check(result.collection_completed and completions == 1, "last episode completes subject")
  check(collection_reads == 1 and watching_updates == 0, "direct update reuses this round's collection check")
  check(subject_reads == 0, "direct update reuses collection subject.eps without subject request")
  check(table.concat(trace, ",") == "write,read,complete", "verify only after confirmed write")
  check(result.collection_update_message == "条目状态更新：看过", "report completion")
  update(100)
  check(completions == 1, "already completed subject is not written again")
  check(collection_reads == 2, "each new update checks once without a duplicate completion query")

  for _, initial_status in ipairs({0, 1, 4, 5}) do
    reset(true)
    collection_type = initial_status ~= 0 and initial_status or nil
    collection_code = initial_status == 0 and 404 or 200
    result = update(100, {batch = true})
    check(result.collection_completed and collection_reads == 1 and watching_updates == 1,
      "reuse the confirmed watching status after creating or updating collection")
    check(subject_reads == (initial_status == 0 and 1 or 0),
      "only trust subject.eps from a successful collection response")
  end
  reset(true)
  collection_type, watching_code = 1, 0
  check(update(100) == nil and direct_calls == 0 and completions == 0,
    "unconfirmed watching update must not be reused as successful")

  reset(true)
  episodes[1].type = 0
  update(100)
  check(completions == 0, "missing earlier episode blocks completion")
  reset(true)
  episodes[2].type = 2
  update(900)
  check(completions == 0, "ordinary episode does not trigger last-episode completion")
  reset(true)
  update(999)
  check(completions == 0, "special or unknown episode does not complete subject")
  reset(true)
  episodes[2].episode.type = 1
  update(100)
  check(completions == 0, "special episode cannot masquerade as final main episode")
  for _, n in ipairs({0, 3}) do
    reset(true)
    expected_eps = n
    collection_subject.eps = n
    update(100)
    check(completions == 0, "unknown or incompletely entered episode count is rejected")
  end
  reset(true)
  total = 3
  update(100)
  check(completions == 0, "partial list is rejected")
  reset(true)
  episodes, total = {}, 0
  update(100)
  check(completions == 0, "empty list is rejected")
  for _, code in ipairs({0, 302, 401, 500}) do
    reset(true)
    episode_code = code
    check(update(100) == nil and completions == 0 and reads == 0, "failed write cannot complete")
  end
  reset(true)
  list_code = 503
  check(not update(100).collection_completed and completions == 0, "list failure preserves successful episode update")
  reset(true)
  collection_subject = nil
  subject_code = 503
  update(100)
  check(completions == 0, "subject request failure blocks completion")
  reset(true)
  complete_code = 500
  result = update(100)
  check(result.success and not result.collection_completed and collection_type == 3,
    "completion failure must not falsely report watched")
  reset(true)
  result = update(100, {status = 0})
  check(result.success and completions == 0 and reads == 0, "unwatch never completes")

  reset(true)
  result = update(100, {batch = true})
  check(result.flushed and result.collection_completed, "immediate batch completes")
  check(collection_reads == 1, "immediate batch removes the fifth request")
  check(subject_reads == 0 and collection_reads + batch_calls + reads + completions == 4,
    "immediate batch completes in four requests")
  reset(true)
  episodes[1].type = 0
  result = update(900, {batch = true, threshold = 2})
  check(result.deferred and reads == 0 and batch_calls == 0, "queue is not treated as synced")
  result = update(100, {batch = true, threshold = 2})
  check(result.collection_completed and batch_calls == 1, "final batch syncs all before completion")
  check(collection_reads == 2, "threshold flush reuses the newest collection check")
  check(subject_reads == 0, "threshold flush also reuses total episode count")
  for _, threshold in ipairs({0, 4}) do
    reset(true)
    check(update(100, {batch = true, threshold = threshold}).deferred, "defer below threshold")
    result = service.flush_pending({detach = true})
    check(#result == 1 and result[1].collection_completed and detached == false,
      "shutdown waits for write before completion")
    check(collection_reads == 2, "deferred flush gets fresh collection state")
    check(subject_reads == 0, "deferred flush gets total from its fresh collection query")
    check(#service.flush_pending({}) == 0 and completions == 1, "successful batch is cleared")
  end
  reset(false)
  update(100, {batch = true, threshold = 0})
  service.flush_pending({detach = true})
  check(detached == true and reads == 0, "disabled preserves detached shutdown")
  reset(true)
  episode_code = 500
  result = update(100, {batch = true})
  check(result.flush_failed and reads == 0 and completions == 0, "failed batch cannot complete")
  episode_code = 204
  result = service.flush_pending({})
  check(#result == 1 and result[1].collection_completed, "failed batch retained for retry")
  check(collection_reads == 2, "retry does not reuse the failed round's collection state")
  check(subject_reads == 0, "retry uses fresh collection total instead of a separate subject request")
  reset(true)
  update(100, {batch = true, threshold = 0})
  collection_type = 2
  result = service.flush_pending({detach = true})
  check(#result == 1 and not result[1].collection_completed and collection_reads == 2 and completions == 0,
    "deferred flush detects a subject marked watched elsewhere")

  -- Missing/invalid collection metadata falls back without skipping completeness checks.
  for _, subject in ipairs({false, "invalid", {}, {eps = 0}, {eps = -1}, {eps = 2.5}, {eps = "unknown"}}) do
    reset(true)
    collection_subject = subject
    result = update(100, {batch = true})
    check(result.collection_completed and subject_reads == 1 and collection_reads == 1,
      "invalid or missing collection total falls back to subject details exactly once")
  end
  reset(true)
  collection_subject.eps = "2"
  check(update(100).collection_completed and subject_reads == 0, "numeric string total is usable")
  reset(true)
  collection_subject.eps = 3
  update(100)
  check(completions == 0 and subject_reads == 0,
    "known larger total blocks completion without a redundant subject query")
  reset(true)
  collection_subject = nil
  expected_eps = 0
  update(100)
  check(completions == 0 and subject_reads == 1, "unknown total in fallback still blocks completion")
  reset(true)
  update(100, {batch = true, threshold = 0})
  collection_subject.eps = 3
  service.flush_pending({detach = true})
  check(completions == 0 and subject_reads == 0 and collection_reads == 2,
    "deferred flush uses updated total, not metadata from enqueue time")
  reset(true)
  update(100, {batch = true, threshold = 0})
  collection_subject = nil
  result = service.flush_pending({detach = true})
  check(result[1].collection_completed and subject_reads == 1 and collection_reads == 2,
    "deferred flush falls back when fresh collection lacks total")
  reset(true)
  result = update(100, {batch = true, auto_mark_enabled = false})
  check(result.disabled and batch_calls == 0 and completions == 0, "auto mark switch respected")
  reset(true)
  update(100, {batch = true, threshold = 0})
  config.options.enable_auto_mark = false
  check(#service.flush_pending({}) == 0, "disabled auto mark suppresses ordinary flush")
  result = service.flush_pending({force = true})
  check(#result == 1 and result[1].collection_completed, "forced pending flush can complete")
end

local ok, err = xpcall(run, debug.traceback)
if ok then host.msg.info("PASS: " .. count .. " checks") else host.msg.error(err) end
host.commandv("quit", ok and "0" or "1")
