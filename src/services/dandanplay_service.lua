local dandanplay_api = require "src.dandanplay_api"
local sync_context = require "src.services.sync_context"

local M = {}

function M.dandanplay_search(keyword, callback)
    dandanplay_api.search_anime(keyword, nil, function(results, res)
        if not res or not res.body then
            if callback then callback(nil, "search failed") end
            return
        end
        local formatted = {}
        for _, result in ipairs(results or {}) do
            formatted[#formatted + 1] = { id = result.animeId, title = result.animeTitle, type = result.type }
        end
        if callback then callback(formatted) end
    end)
end

-- 获取剧集列表
function M.get_dandanplay_episodes(anime_id, callback)
    sync_context.get_anime_info_cached(anime_id * 10000 + 1, anime_id, {force_refresh = false}, function(anime_info)
        local episodes = {}
        if anime_info and anime_info.episodes then
            for _, episode in ipairs(anime_info.episodes) do
                episodes[#episodes + 1] = { id = episode.episodeId, title = episode.episodeTitle }
            end
        end
        if callback then callback(episodes) end
    end)
end

return M
