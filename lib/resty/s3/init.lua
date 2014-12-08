local mod_name = "resty.s3."

local mongol = require "resty.mongol"
local lfs = require "lfs"
local handler = require (mod_name.."handler")
local cachel = require (mod_name.."cachel")

local resource = ngx.var.resource or "misc"

local db_host = ngx.var.db_host or "127.0.0.1"
local db_port = ngx.var.db_port or 27017
local db_name = ngx.var.db_name or resource
local db_user = ngx.var.db_user or ""
local db_passwd = ngx.var.db_passwd or ""

local cache_dir = ngx.var.cache_dir or "/tmp/nginx_cache/"

local chunk_size = ngx.var.chunk_size or 4096
local read_timeout = ngx.var.read_timeout or 3600

local with_sign = ngx.var.with_sign or false

local conn = mongol:new()
local ok, err = conn:connect(db_host, db_port)
if not ok then
    ngx.log(ngx.ERR, "failed to connect db: ", err)
    ngx.exit(500)
end

local ok, err = conn:new_db_handle("admin"):auth(db_user, db_passwd)
if not ok then
    ngx.log(ngx.ERR, "failed to auth db: ", err)
    ngx.exit(500)
end

local db = conn:new_db_handle(db_name)

local r, err = lfs.attributes(cache_dir, "mode")
if not r or r ~= "directory" then
    local ok, err = lfs.mkdir(cache_dir)
    if not ok then
        ngx.log(ngx.ERR, "failed to init cache dir: ", err)
    end
end

local cache = cachel:new(cache_dir)

local m = ngx.re.match(ngx.var.uri, "/"..resource.."(.*)")
local path = nil
local bucket_name = nil
local object_name = nil
if m then path = m[1] end

if path and path ~= "/" and path ~= "" then
    local m, err = ngx.re.match(path, "/(?<obj_bct>.*?)/(?<obj>.*)|/(?<bct>.*)")
    if m then
        if m["bct"] or (m["obj_bct"] and (not m["obj"] or m["obj"] == "")) then
            bucket_name = m["bct"] or m["obj_bct"]
        else
            bucket_name, object_name = m["obj_bct"], m["obj"]
        end
    else
        ngx.log(ngx.ERR, "invalid uri")
        ngx.exit(404)
    end
end

local _h = handler:new({
    document_uri = ngx.var.document_uri,
    uri_args = ngx.req.get_uri_args(),
    ngx_say = ngx.say,
    ngx_print = ngx.print,
    ngx_exit = ngx.exit,
    ngx_log = ngx.log,
    ngx_err_flag = ngx.ERR,
    ngx_re_match = ngx.re.match,
    db = db,
    cache = cache,
    chunk_size = chunk_size,
    read_timeout = read_timeout
})


if with_sign and not _h:check_sign() then
    ngx.log(ngx.ERR, "failed to check sign")
    ngx.exit(401)
end

local method = ngx.var.request_method
if method == "GET" then
    if not bucket_name then
        _h:list_bucket()
    elseif bucket_name and object_name then
        _h:get_object(bucket_name, object_name)
    else
        _h:list_object(bucket_name)
    end
end

if method == "POST" then
    if bucket_name and object_name then
        _h:put_object(bucket_name, object_name)
    else
        ngx.exit(405)
    end
end

if method == "PUT" then
    if bucket_name and not object_name then
        _h:put_bucket(bucket_name)
    else
        ngx.exit(405)
    end
end

if method == "DELETE" then
   if bucket_name and object_name then
       _h:delete_object(bucket_name, object_name)
   elseif bucket_name then
       _h:delete_bucket(bucket_name)
   else
       ngx.exit(405)
   end
end
