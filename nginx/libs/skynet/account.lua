local _M = {}

-- imports
local skynet_utils = require("skynet.utils")

-- constant tier ids
local tier_id_anonymous = 0
local tier_id_free = 1

-- fallback - remember to keep those updated
local anon_limits = {
    ["tierID"] = tier_id_anonymous,
    ["tierName"] = "anonymous",
    ["upload"] = 5242880,
    ["download"] = 5242880,
    ["maxUploadSize"] = 1073741824,
    ["registry"] = 250
}

-- get all non empty authentication headers from request, we want to return
-- all of them and let accounts service deal with validation and prioritisation
function _M.get_auth_headers()
    local utils = require("utils")
    local request_headers = ngx.req.get_headers()
    local headers = {}

    -- try to extract skynet-jwt cookie from cookie header
    local skynet_jwt_cookie = utils.extract_cookie(request_headers["Cookie"], "skynet[-]jwt")

    -- if skynet-jwt cookie is present, pass it as is
    if skynet_jwt_cookie then
        headers["Cookie"] = skynet_jwt_cookie
    end

    -- if authorization header is set, pass it as is
    if request_headers["Authorization"] then
        headers["Authorization"] = request_headers["Authorization"]
    end

    -- if skynet api key header is set, pass it as is
    if request_headers["Skynet-Api-Key"] then
        headers["Skynet-Api-Key"] = request_headers["Skynet-Api-Key"]
    end

    return headers
end

-- check whether there is a redirect URL configured for "account" subdomain.
function _M.should_redirect_accounts()
    local utils = require('utils')
    local has_redirect_url = utils.getenv("ACCOUNTS_REDIRECT_URL") ~= nil

    return has_redirect_url or _M.accounts_disabled()
end

-- handle request exit when access to portal should be restricted to authenticated users only
function _M.exit_access_unauthorized()
    return skynet_utils.exit(ngx.HTTP_UNAUTHORIZED)
end

-- handle request exit when access to portal should be restricted to subscription users only
function _M.exit_access_forbidden()
    return skynet_utils.exit(
        ngx.HTTP_FORBIDDEN,
        "Portal operator restricted access to users with active subscription only"
    )
end

function _M.accounts_enabled()
    local skynet_modules = require("skynet.modules")

    return skynet_modules.is_enabled("a")
end

function _M.accounts_disabled()
    return not _M.accounts_enabled()
end

function _M.get_account_limits()
    local cjson = require('cjson')
    local utils = require('utils')
    local auth_headers = _M.get_auth_headers()

    -- simple case of anonymous request - none of available auth headers exist
    if utils.is_table_empty(auth_headers) then
        return anon_limits
    end

    if ngx.var.account_limits == "" then
        local httpc = require("resty.http").new()
        local uri = "http://10.10.10.70:3000/user/limits"

        -- include skylink if it is available in the context of request
        -- todo: this should not rely on skylink variable to be defined
        if ngx.var.skylink ~= nil and ngx.var.skylink ~= "" then
            uri = uri .. "/" .. ngx.var.skylink
        end

        -- 10.10.10.70 points to accounts service (alias not available when using resty-http)
        local res, err = httpc:request_uri(uri .. "?unit=byte", {
            headers = auth_headers,
        })

        -- fail gracefully in case /user/limits failed
        if err or (res and res.status ~= ngx.HTTP_OK) then
            local error_response = err or ("[HTTP " .. res.status .. "] " .. res.body)
            ngx.log(ngx.ERR, "Failed accounts service request /user/limits?unit=byte: ", error_response)
            ngx.var.account_limits = cjson.encode(anon_limits)
        elseif res and res.status == ngx.HTTP_OK then
            ngx.var.account_limits = res.body
        end
    end

    return cjson.decode(ngx.var.account_limits)
end

-- detect whether current user is authenticated
function _M.is_authenticated()
    if not _M.accounts_enabled() then return false end

    local limits = _M.get_account_limits()

    return limits.tierID > tier_id_anonymous
end

-- detect whether current user has active subscription
function _M.has_subscription()
    local limits = _M.get_account_limits()

    return limits.tierID > tier_id_free
end

function _M.is_auth_required()
    -- authentication is required if mode is set to "authenticated"
    -- or "subscription" (require active subscription to a premium plan)
    return os.getenv("ACCOUNTS_LIMIT_ACCESS") == "authenticated" or _M.is_subscription_required()
end

function _M.is_subscription_required()
    return os.getenv("ACCOUNTS_LIMIT_ACCESS") == "subscription"
end

local is_access_always_allowed = function ()
    -- options requests do not attach cookies - should always be available
    -- requests should not be limited based on accounts if accounts are not enabled
    return ngx.req.get_method() == "OPTIONS" or not _M.accounts_enabled()
end

-- check whether access is restricted if portal requires authorization
function _M.is_access_unauthorized()
    if is_access_always_allowed() then return false end

    -- check if authentication is required and request is not authenticated
    return _M.is_auth_required() and not _M.is_authenticated()
end

-- check whether user is authenticated but does not have access to given resources
function _M.is_access_forbidden()
    if is_access_always_allowed() then return false end

    -- check if active subscription is required and request is from user without it
    return _M.is_subscription_required() and not _M.has_subscription()
end

return _M
