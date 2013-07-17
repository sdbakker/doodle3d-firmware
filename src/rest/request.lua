local util = require('util.utils') -- required for string:split()
local urlcode = require('util.urlcode')
local confDefaults = require('conf_defaults')
local s = require('util.settings')
local ResponseClass = require('rest.response')

local M = {}
M.__index = M

local GLOBAL_API_FUNCTION_NAME = '_global'


--NOTE: requestedApi* contain what was extracted from the request data
--  regarding the other variables: either both resolvedApiFunction and realApiFunctionName
--  are nil and resolutionError is not, or exactly the other way around
M.requestedApiModule = nil
M.requestedApiFunction = nil
M.resolvedApiFunction = nil --will contain function address, or nil
M.realApiFunctionName = nil --will contain requested name, or global name, or nil
M.resolutionError = nil --non-nil means function could not be resolved


local function kvTableFromUrlEncodedString(encodedText)
	local args = {}
	if (encodedText ~= nil) then
		urlcode.parsequery(encodedText, args)
	end
	return args

end

local function kvTableFromArray(argArray)
	local args = {}
	
	if not argArray then return args end
	
	for _, v in ipairs(argArray) do
		local split = v:find("=")
		if split ~= nil then
			args[v:sub(1, split - 1)] = v:sub(split + 1)
		else
			args[v] = true
		end
	end
	
	return args
end

--- Create an array from the given '/'-separated path.
-- Empty path elements are not ignored (e.g. '/a//b' yields { [1] = '', [2] = 'a', [3] = '', [4] = 'b' }).
-- @param pathText The path to split.
-- @return An array with the path elements.
local function arrayFromPath(pathText)
	return pathText and pathText:split('/') or {}
end

--- Resolve the given module name.
-- Modules are searched for in the 'rest.api' path, with their name prefixed by 'api_'.
-- e.g. if modname is 'test', then the generated 'require()' path will be 'rest.api.api_test'.
-- Furthermore, the module must have the table key 'isApi' set to true.
-- @param modname The basename of the module to resolve.
-- @return Either a module object, or nil on error
-- @return An message on error, or nil otherwise
-- @see resolveApiFunction
local function resolveApiModule(modname)
	if modname == nil then return nil, "missing module name" end
	if string.find(modname, '_') == 1 then return nil, "module names starting with '_' are preserved for internal use" end
	
	local reqModName = 'rest.api.api_' .. modname
	local ok, modObj
	
	if confDefaults.DEBUG_PCALLS then ok, modObj = true, require(reqModName)
	else ok, modObj = pcall(require, reqModName)
	end
	
	if ok == false then return nil, "API module does not exist" end
	if modObj == nil then return nil, "API module could not be found" end
	if modObj.isApi ~= true then return nil, "module is not part of the CGI API" end
	
	return modObj
end

--- Resolves a module/function name pair with appropiate access for the given request method.
-- First, the function name suffixed with the request method, if not found the plain
-- function name is looked up.
-- Returned result data contains a 'func' key and if found, also 'blankArg'.
-- @param modname Basename of the module to resolve funcname in.
-- @param funcname Basename of the function to resolve.
-- @param requestMethod Method by which the request was received.
-- @return A table with resultData or nil on error.
-- @return A message on error (unresolvable or inaccessible).
-- @see resolveApiModule
local function resolveApiFunction(modname, funcname, requestMethod)
	local resultData = {}
	
	if funcname and string.find(funcname, "_") == 1 then return nil, "function names starting with '_' are preserved for internal use" end
	
	local mod, msg = resolveApiModule(modname)
	
	if mod == nil then
		return nil, msg
	end
	
	if (funcname == nil or funcname == '') then funcname = GLOBAL_API_FUNCTION_NAME end --treat empty function name as nil
	local rqType = requestMethod == 'POST' and 'POST' or 'GET'
	local fGeneric = mod[funcname]
	local fWithMethod = mod[funcname .. '_' .. rqType]
	local funcNumber = tonumber(funcname)
	
	if (type(fWithMethod) == 'function') then
		resultData.func = fWithMethod
	elseif (type(fGeneric) == 'function') then
		resultData.func = fGeneric
	elseif funcNumber ~= nil then
		resultData.func = mod[GLOBAL_API_FUNCTION_NAME .. '_' .. rqType]
		if not resultData.func then resultData.func = mod[GLOBAL_API_FUNCTION_NAME] end
		resultData.blankArg = funcNumber
	else
		return nil, ("function '" .. funcname .. "' does not exist in API module '" .. modname .. "'")
	end
	
	return resultData
end


setmetatable(M, {
	__call = function(cls, ...)
		return cls.new(...)
	end
})

--This function initializes itself using various environment variables, the arg array and the given postData
--NOTE: if debugging is enabled, commandline arguments 'm' and 'f' override requested module and function
function M.new(postData, debugEnabled)
	local self = setmetatable({}, M)
	
	--NOTE: is it correct to assume that absence of REQUEST_METHOD indicates command line invocation?
	self.requestMethod = os.getenv('REQUEST_METHOD')
	if self.requestMethod ~= nil then
		self.remoteHost = os.getenv('REMOTE_HOST')
		self.remotePort = os.getenv('REMOTE_PORT')
		self.userAgent = os.getenv('HTTP_USER_AGENT')
	else
		self.requestMethod = 'CMDLINE'
	end
	
	self.cmdLineArgs = kvTableFromArray(arg)
	self.getArgs = kvTableFromUrlEncodedString(os.getenv('QUERY_STRING'))
	self.postArgs = kvTableFromUrlEncodedString(postData)
	self.pathArgs = arrayFromPath(os.getenv('PATH_INFO'))
	
	-- override path arguments with command line parameter and allow to emulate GET/POST if debugging is enabled
	if debugEnabled and self.requestMethod == 'CMDLINE' then
		self.pathArgs = arrayFromPath(self.cmdLineArgs['p'])
		
		if self.cmdLineArgs['r'] == 'GET' then
			self.requestMethod = 'GET'
			self.getArgs = self.cmdLineArgs
			self.getArgs.p, self.getArgs.r = nil, nil
		elseif self.cmdLineArgs['r'] == 'POST' then
			self.requestMethod = 'POST'
			self.postArgs = self.cmdLineArgs
			self.postArgs.p, self.postArgs.r = nil, nil
		end
	end
	table.remove(self.pathArgs, 1) --drop the first 'empty' field caused by the opening slash of the query string
	
	
	if #self.pathArgs >= 1 then self.requestedApiModule = self.pathArgs[1] end
	if #self.pathArgs >= 2 then self.requestedApiFunction = self.pathArgs[2] end
	
	if self.requestedApiModule == '' then self.requestedApiModule = nil end
	if self.requestedApiFunction == '' then self.requestedApiFunction = nil end
	
	
	-- Perform module/function resolution
	local rData, errMsg = resolveApiFunction(self:getRequestedApiModule(), self:getRequestedApiFunction(), self.requestMethod)
	
	if rData ~= nil and rData.func ~= nil then --function (possibly the global one) could be resolved
		self.resolvedApiFunction = rData.func
		if rData.blankArg ~= nil then --apparently it was the global one, and we received a 'blank argument'
			self:setBlankArgument(rData.blankArg)
			self.realApiFunctionName = GLOBAL_API_FUNCTION_NAME
		else --resolved without blank argument but still potentially the global function, hence the _or_ construction
			if self:getRequestedApiFunction() ~= nil then
				self.realApiFunctionName = self:getRequestedApiFunction()
				if #self.pathArgs >= 3 then self:setBlankArgument(self.pathArgs[3]) end --aha, we have both a function and a blank argument
			else
				self.realApiFunctionName = GLOBAL_API_FUNCTION_NAME
			end
		end
	else
		--instead of throwing an error, save the message for handle() which is expected to return a response anyway
		self.resolutionError = errMsg
	end
	
	
	return self
end

function M:getRequestMethod() return self.requestMethod end --returns either GET or POST or CMDLINE
function M:getRequestedApiModule() return self.requestedApiModule end
function M:getRequestedApiFunction() return self.requestedApiFunction end
function M:getRealApiFunctionName() return self.realApiFunctionName end
function M:getBlankArgument() return self.blankArgument end
function M:setBlankArgument(arg) self.blankArgument = arg end
function M:getRemoteHost() return self.remoteHost or "" end
function M:getRemotePort() return self.remotePort or 0 end
function M:getUserAgent() return self.userAgent or "" end

function M:get(key)
	if self.requestMethod == 'GET' then
		return self.getArgs[key]
	elseif self.requestMethod == 'POST' then
		return self.postArgs[key]
	elseif self.requestMethod == 'CMDLINE' then
		return self.cmdLineArgs[key]
	else
		return nil
	end
end

function M:getAll()
	if self.requestMethod == 'GET' then
		return self.getArgs
	elseif self.requestMethod == 'POST' then
		return self.postArgs
	elseif self.requestMethod == 'CMDLINE' then
		return self.cmdLineArgs
	else
		return nil
	end
end

function M:getPathData()
	return self.pathArgs
end

--returns either a response object+nil, or response object+errmsg
function M:handle()
	local modname = self:getRequestedApiModule()
	local resp = ResponseClass.new(self)
	
	if (self.resolvedApiFunction ~= nil) then --we found a function (possible the global function)
		--invoke the function
		local ok, r
		if confDefaults.DEBUG_PCALLS then ok, r = true, self.resolvedApiFunction(self, resp)
		else ok, r = pcall(self.resolvedApiFunction, self, resp)
		end
		
		--handle the result
		if ok == true then
			return resp, nil
		else
			resp:setError("call to function '" .. modname .. "/" .. self.realApiFunctionName .. "' failed")
			return resp, ("calling function '" .. self.realApiFunctionName .. "' in API module '" .. modname .. "' somehow failed ('" .. r .. "')")
		end
	else
		resp:setError("function or module unknown '" .. (modname or "<empty>") .. "/" .. (self:getRequestedApiFunction() or "<empty>") .. "'")
		return resp, ("could not resolve requested API function ('" .. self.resolutionError .. "')")
	end
	
	return resp
end

return M
