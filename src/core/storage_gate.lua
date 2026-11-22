
local config = require "src.config"

local M = {}

local function is_windows()
    if mp and mp.get_property_native then
        return mp.get_property_native("platform") == "windows"
    end
    return package.config:sub(1, 1) == "\\"
end

-- 供比较用的归一化：统一分隔符；Windows 下忽略大小写
local function normalize_for_compare(path)
    if not path then return nil end
    local p = path:gsub("\\", "/")
    if is_windows() then p = p:lower() end
    return p
end

-- 双保险：storage 以 "/" 结尾（config 层已归一化时此为 no-op）
local function normalize_storage(storage)
    if not storage then return nil end
    local s = normalize_for_compare(storage)
    if s:sub(-1) ~= "/" then s = s .. "/" end
    return s
end

-- 带路径边界的前缀匹配：必须命中 "<storage>/..."，杜绝 "<storage>OtherDir" 误配
local function has_path_prefix(file_path, storage)
    return file_path:sub(1, #storage) == storage
end

function M.is_in_storage_path(file_path, storages)
    if type(file_path) ~= "string" or file_path == "" then return false end
    local list = storages or (config.config and config.config.storages)
    if type(list) ~= "table" then return false end
    local normalized_path = normalize_for_compare(file_path)
    for _, storage in ipairs(list) do
        local s = normalize_storage(storage)
        if s and has_path_prefix(normalized_path, s) then
            return true
        end
    end
    return false
end

function M.resolve_storage(file_path)
    if type(file_path) ~= "string" or file_path == "" then return nil end
    local cfg = config.config
    if type(cfg) ~= "table" or type(cfg.storage_groups) ~= "table" then return nil end
    local normalized_path = normalize_for_compare(file_path)
    local best
    for _, group in ipairs(cfg.storage_groups) do
        if type(group and group.storages) == "table" then
            for _, storage in ipairs(group.storages) do
                local s = normalize_storage(storage)
                if s and has_path_prefix(normalized_path, s) then
                    if not best or #s > best.match_length then
                        best = {
                            key = group.key,
                            storages = group.storages,
                            batch_sync_threshold = group.batch_sync_threshold,
                            matched_storage = storage,   -- 返回原始写法，供展示
                            match_length = #s,
                        }
                    end
                end
            end
        end
    end
    return best
end

return M
