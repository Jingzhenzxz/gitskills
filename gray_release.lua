local core = require("apisix.core")
local http = require("resty.http")
local lrucache = require("resty.lrucache")
local json = require("apisix.core.json")
local balancer = require("apisix.balancer")

local plugin_name = "gray_release"

local _M = {
    version = 0.1,
    priority = 1000,
    type = 'rewrite',  -- 修改插件类型为 rewrite
    name = plugin_name,
    schema = {
        type = "object",
        properties = {
            key = {type = "string", minLength = 1, maxLength = 100},
            gray_route_api = {type = "string", minLength = 1, maxLength = 1000},
        },
        required = {"gray_route_api"},
    },
}

-- initialize the cache
local cache, err = lrucache.new(200)  -- allow up to 200 items in the cache
core.log.warn("初始化 cache")
if not cache then
    return error("failed to create the cache: " .. (err or "unknown"))
end

local function fetch_data(route)
    local httpc = http.new()
    local res, err = httpc:request_uri(route, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json",
        }
    })
    
    if not res then
        core.log.error("failed to fetch data from ", route, ": ", err)
        return nil
    end
    
    if res.status ~= 200 then
        core.log.error("failed to fetch data from ", route, ": status ", res.status)
        return nil
    end

    local data = json.decode(res.body)
    if not data then
        core.log.error("failed to parse data from ", route)
        return nil
    end

    return data
end

local function fetch_and_cache_routes(conf)
    local routes = fetch_data(conf.gray_route_api).data.rows
    core.log.warn("所有路由为：", core.json.encode(routes))

    if routes then
        for _, route in ipairs(routes) do
            core.log.warn("路由为：", core.json.encode(route))
            local key = route.systemId .. "_" .. route.grayLevel
            core.log.warn("key 为：", key)
            core.log.warn("目标地址为：", core.json.encode(route.targetUrl))
            cache:set(key, route.targetUrl)
        end
    end
end

-- function _M.init()
--     core.log.warn("进入 init 阶段")
--     local local_conf = core.config.local_conf()
--     core.log.warn("local_conf 为：", core.json.encode(local_conf))

--     if local_conf.plugin_attr and local_conf.plugin_attr[plugin_name] then
--         fetch_and_cache_routes(local_conf.plugin_attr[plugin_name])
--     end
-- end

function _M.check_schema(conf)
    core.log.warn("进入 check_schema 阶段")
    return core.schema.check(_M.schema, conf)
end

-- 在rewrite阶段被调用
function _M.rewrite(conf, ctx)
    core.log.warn("进入 rewrite 阶段")
    core.log.warn("ctx.matched_route 为：", core.json.encode(ctx.matched_route))

    fetch_and_cache_routes(conf)

    local env = ctx.var["cookie_gray-level"]
    core.log.warn("env 为：", env)
    local systemId = ctx.var.cookie_systemId
    core.log.warn("systemId 为：", systemId)
    if not systemId or not env then
        core.log.error("systemId or env is missing")
        return
    end

    local key = systemId .. "_" .. env
    local upstream = cache:get(key)
    core.log.warn("rewrite 阶段获得的 upstream 为：", upstream)
    if upstream then
        -- 我们假设 upstream 的格式是 "ip:port"
        local ip, port = upstream:match("([^:]+):?(.*)")
        port = tonumber(port)

        core.log.warn("ip 为：", ip)
        core.log.warn("port 为：", port)
        
        if ip and port then
            -- 创建新的上游配置
            local new_upstream = {
                type = 'roundrobin', --设置成默认的 roundrobin
                nodes = {[ip .. ":" .. port] = 1}, -- 使用新的 ip 和 port
            }

            -- 创建新的 Balancer 实例
            local checker = ctx.up_checker
            local server_picker, err = balancer.create_server_picker(new_upstream, checker)
            
            if not server_picker then
                core.log.warn("failed to create server picker: ", err)
                return 503, "failed to create new server picker"
            end
        else
            core.log.error("无法解析 upstream 地址：", upstream)
            return 503, "无法解析 upstream 地址"
        end
    else
        core.log.error("no route for ", key)
    end
end

return _M
