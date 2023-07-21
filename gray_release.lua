local core = require("apisix.core")
local http = require("resty.http")
local lrucache = require("resty.lrucache")
local json = require("apisix.core.json")

-- 定义一个插件
local plugin_name = "gray_release"

local _M = {
    version = 0.1,
    priority = 1000,
    type = 'balancer',
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
local c, err = lrucache.new(200)  -- allow up to 200 items in the cache
if not c then
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
            c:set(key, route.targetUrl)
        end
    end
end

function _M.init()
    local local_conf = core.config.local_conf()
    if local_conf.plugin_attr and local_conf.plugin_attr[plugin_name] then
        fetch_and_cache_routes(local_conf.plugin_attr[plugin_name])
    end
end

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end

-- 在balancer阶段被调用
function _M.balancer(conf, ctx)
    core.log.warn("进入 balancer 阶段")
    local upstream = ctx.upstream -- 在access阶段保存的上游地址
    core.log.warn("balancer 阶段获得的 upstream 为：", upstream)

    if upstream then
        -- 我们假设 upstream 的格式是 "ip:port"
        local ip, port = upstream:match("([^:]+):?(.*)")
        port = tonumber(port)

        if ip and port then
            -- 设置当前请求的上游
            local addr = ctx.balancer_address
            addr.ip = ip
            addr.port = port
            core.log.warn("设置的 addr 为：", addr)
        else
            core.log.error("无法解析 upstream 地址：", upstream)
            return 503, "无法解析 upstream 地址"
        end
    else
        core.log.error("没有获取到 access 阶段保存的上游地址")
        return 503, "没有获取到 access 阶段保存的上游地址"
    end
end

-- 在access阶段被调用
function _M.access(conf, ctx)
    fetch_and_cache_routes(conf)

    local env = ctx.var["cookie_lambo-gray-level"]
    core.log.warn("env 为：", env)
    local systemId = ctx.var.cookie_systemId
    core.log.warn("systemId 为：", systemId)
    if not systemId or not env then
        core.log.error("systemId or env is missing")
        return
    end

    local key = systemId .. "_" .. env
    local upstream = c:get(key)
    core.log.warn("access 阶段获得的 upstream 为：", upstream)
    if upstream then
        -- 保存上游地址到ctx
        ctx.upstream = upstream
    else
        core.log.error("no route for ", key)
    end
end

return _M
