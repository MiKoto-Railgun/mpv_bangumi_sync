local http = require "src.http"
local mp_utils = require "mp.utils"
local paths = require "src.paths"
local config = require "src.config"
local json_store = require "src.core.json_store"

local M = {}

local DEFAULT_API_URL = "https://api.bgm.tv"
local API_ERROR_MESSAGE = "Bangumi API 请求失败，请检查 Bangumi 状态或 bangumi_api 配置"
local USERNAME_FILE = mp_utils.join_path(paths.DATA_PATH, "username.json")

local function get_api_url()
    return (config.config and config.config.bangumi_api) or DEFAULT_API_URL
end

local function warn_api_error(res)
    if res and res.detached then return end
    local status_code = res and tonumber(res.status_code or 0) or 0
    if not res or status_code == 0 or status_code >= 500 then
        mp.msg.error(API_ERROR_MESSAGE .. ": " .. tostring(status_code))
        mp.osd_message(API_ERROR_MESSAGE, 4)
    end
end

-- 响应归一化：统一错误结构、告警、status_code 兜底（所有回调路径共用）
local function normalize_response(res)
    if not res then
        res = {status_code = 500, body = {}}
    end
    warn_api_error(res)
    res.status_code = res.status_code or 200
    return res
end

local function get_headers()
    return {
        ["accept"] = "application/json",
        ["User-Agent"] = "mpv_bangumi_sync/private",
        ["Authorization"] = "Bearer " .. (config.config.access_token or ""),
    }
end

local function get_proxy()
    return config.config.bgm_proxy
end

local function get_request_options(extra)
    local proxy = get_proxy()
    local opts = {
        headers = get_headers(),
        proxy = proxy,
        skip_cert_verify = proxy and proxy ~= "" and config.config.bgm_proxy_skip_cert_verify == true,
    }
    for key, value in pairs(extra or {}) do
        opts[key] = value
    end
    return opts
end

-- 统一异步请求入口：所有响应经 normalize 后回调；返回 mpv 请求句柄（可用于 abort）
local function async_request(method, uri, params, data, opts, callback)
    local url = get_api_url() .. uri
    local req = get_request_options({
        method = method,
        params = params,
        data = data,
        detach = (opts and opts.detach) or false,
        callback = function(res) callback(normalize_response(res)) end,
    })
    if not req.detach then req.timeout = 30 end
    return http.request(url, req)
end

local username = nil
local username_pending = nil  -- /v0/me 在途时的回调队列（并发去重）

local function read_username_cache()
    local info = mp_utils.file_info(USERNAME_FILE)
    if info and info.is_file then
        local file = io.open(USERNAME_FILE, "r")
        if file then
            local content = file:read("*all")
            file:close()
            return mp_utils.parse_json(content) or {}
        end
    end
    return {}
end

-- callback(username)：成功给用户名，失败给 nil；恰好回调一次
function M.get_username(callback)
    if username then callback(username) return end
    local access_token = config.config.access_token
    if not access_token then
        mp.msg.error("BGM_ACCESS_TOKEN not found")
        callback(nil) return
    end
    local username_data = read_username_cache()
    if username_data[access_token] then
        username = username_data[access_token]
        callback(username) return
    end
    if username_pending then
        username_pending[#username_pending + 1] = callback
        return
    end
    username_pending = {callback}
    async_request("GET", "/v0/me", nil, nil, nil, function(res)
        local pending = username_pending
        username_pending = nil
        local fetched = res and res.status_code == 200 and res.body and res.body.username
        if fetched then
            username = fetched
            username_data[access_token] = username
            json_store.write(USERNAME_FILE, username_data)
        else
            mp.msg.error("Failed to get username from API")
        end
        if pending then
            for _, cb in ipairs(pending) do cb(fetched) end
        end
    end)
end

-- 拉取所有分页（异步）。callback(res)：全部成功才回调聚合结果；
-- 任一页失败回调失败响应，绝不返回不完整列表
local function get_all_pages(uri, params, callback)
    params.offset = 0
    params.limit = 100
    local data = {}
    local function receive_page(res)
        if not res or tonumber(res.status_code or 0) ~= 200
            or not res.body or type(res.body.data) ~= "table" then
            callback(res)
            return
        end
        local page = res.body.data
        for _, item in ipairs(page) do
            data[#data + 1] = item
        end
        params.offset = params.offset + #page
        local total = tonumber(res.body.total)
        if #page == 0 and total and params.offset < total then
            callback({status_code = 502, body = {error = "incomplete episode list"}})
            return
        end
        if #page == 0 or (total and params.offset >= total) or (not total and #page < params.limit) then
            res.body.data = data
            callback(res)
            return
        end
        async_request("GET", uri, params, nil, nil, receive_page)
    end
    async_request("GET", uri, params, nil, nil, receive_page)
end

-- 获取用户收藏
function M.get_user_collection(subject_id, callback)
    M.get_username(function(u)
        if not u then
            callback({status_code = 401, body = {error = "Username not available"}})
            return
        end
        async_request("GET", string.format("/v0/users/%s/collections/%d", u, subject_id),
            nil, nil, nil, callback)
    end)
end

-- 更新用户收藏（无 callback 时为 fire-and-forget，失败仍会告警）
function M.update_user_collection(subject_id, status, private, callback)
    status = status or 3
    private = private or false
    async_request("POST", string.format("/v0/users/-/collections/%d", subject_id),
        nil, {type = status, private = private}, nil, callback or function() end)
end

-- 仅更新已有收藏的状态，保留隐私、评分、标签和短评
function M.update_user_collection_status(subject_id, status, callback)
    async_request("PATCH", string.format("/v0/users/-/collections/%d", subject_id),
        nil, {type = status}, nil, callback or function() end)
end

-- 获取剧集状态
function M.get_episode_status(episode_id, callback)
    async_request("GET", string.format("/v0/users/-/collections/-/episodes/%d", episode_id),
        nil, nil, nil, callback)
end

-- 更新剧集状态
function M.update_episode_status(episode_id, status, callback)
    status = status or 2
    async_request("PUT", string.format("/v0/users/-/collections/-/episodes/%d", episode_id),
        nil, {type = status}, nil, callback or function() end)
end

-- 批量更新剧集状态（opts.callback 可选；opts.detach=true 用于退出时 flush）
function M.update_episodes_status(subject_id, episode_ids, status, opts)
    status = status or 2
    opts = opts or {}
    async_request("PATCH", string.format("/v0/users/-/collections/%d/episodes", subject_id),
        nil, {episode_id = episode_ids, type = status}, opts, opts.callback or function() end)
end

-- 不限定章节类型，让手动选择也能覆盖特别篇、OP、ED 等
function M.get_subject_episodes(subject_id, callback)
    get_all_pages("/v0/episodes", {subject_id = subject_id}, callback)
end

function M.get_user_episodes(subject_id, opts, callback)
    local params = {}
    if not (opts and opts.all_types) then params.episode_type = 0 end
    get_all_pages(string.format("/v0/users/-/collections/%d/episodes", subject_id), params, callback)
end

-- 搜索条目
function M.search_subjects(keyword, opts)
    keyword = tostring(keyword or "")
    if keyword == "" then
        if opts and opts.callback then
            opts.callback({status_code = 400, body = {error = "keyword is empty"}})
        end
        return
    end
    opts = opts or {}
    async_request("POST", "/v0/search/subjects", nil, {
        keyword = keyword,
        limit = tonumber(opts.limit) or 20,
        offset = tonumber(opts.offset) or 0,
        sort = opts.sort,
        filter = { type = (opts.type_filter == nil and {2} or opts.type_filter) },
    }, nil, opts.callback or function() end)
end

-- 获取条目详情
function M.get_subject(subject_id, callback)
    subject_id = tonumber(subject_id)
    if not subject_id then
        callback({status_code = 400, body = {error = "invalid subject_id"}})
        return
    end
    async_request("GET", string.format("/v0/subjects/%d", subject_id), nil, nil, nil, callback)
end

-- 缓存缺失时异步补齐列表，与当前匹配缓存保持相同的数据范围。
-- 返回取消函数（菜单关闭时调用以中止在途请求）
function M.get_user_episodes_async(subject_id, callback, opts)
    local items, offset = {}, 0
    local cancelled, request_id = false, nil
    local fetch_page
    local function receive_page(res)
        if cancelled then return end
        local body = res and res.body
        if not res or tonumber(res.status_code) ~= 200 or type(body) ~= "table"
            or type(body.data) ~= "table" then
            callback(nil)
            return
        end
        for _, item in ipairs(body.data) do
            items[#items + 1] = item
        end
        offset = offset + #body.data
        local total = tonumber(body.total)
        if total and offset >= total then
            callback({data = items, total = offset})
            return
        end
        if #body.data == 0 then
            callback(not total and {data = items, total = offset} or nil)
            return
        end
        fetch_page()
    end
    fetch_page = function()
        local params = {offset = offset, limit = 1000}
        if not (opts and opts.all_types) then params.episode_type = 0 end
        request_id = http.get(
            get_api_url() .. string.format("/v0/users/-/collections/%d/episodes", subject_id),
            get_request_options({params = params, callback = receive_page, timeout = 30})
        )
    end
    fetch_page()
    return function()
        cancelled = true
        if request_id then mp.abort_async_command(request_id) end
    end
end

return M
