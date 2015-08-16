-- TODO: Add pkg.create().
-- TODO: Bin support in lj/bin (config.lua for version choice).
-- TODO: Use info.relative_dir for add, remove, update ecc ecc. 
-- TODO: Have status(), available(), return info tables.
-- TODO: Caching of downloaded __repo.lua (zips are already cached), update
-- TODO: every X minutes, or have faster check for version.
-- TODO: Replace unzip with a compression library.
-- TODO: We are sorting vinfo more then necessary, optimize.
-- TODO: Refactoring toward more readable code.

local coremodule = { luajit = true, pkg = true }
local repoaddr = 'http://scilua.org/pkg/'

local modp_root_ver_spec_fmt = '([^%.]*)%.(%d+_?%d*_?%d*_?%a*%d*%+?%d*)%.?(.*)'
local modp_root_spec_fmt     = '([^%.]*)%.?(.*)'
local modz_root_ver_fmt      = '(.-)~(%d+%.?%d*%.?%d*%.?%a*%d*%-?%d*)%.zip'
local ver_components_fmt     = '(%d+)%.?(%d*)%.?(%d*)%.?(%a*)(%d*)%-?(%d*)'

local function topath(verstr)
  return verstr:gsub('%.', '_'):gsub('-', '+')
end

local function tover(verstr)
  return verstr:gsub('_', '.'):gsub('+', '-')
end

local function modzrootver(s)
  local _, _, r, v = s:find(modz_root_ver_fmt)
  return r, v
end

-- TODO: LUA_VER= --> LUA=.
-- TODO: Allow for chosing ARCH=32/64.
local luabincmd = [[
@echo off
SETLOCAL
if defined LUA_VER (
  if "%LUA_VER%"=="2.1" (
    {V21CMD}
  ) else (
    if "%LUA_VER%"=="2.0" (
      {V20CMD}
    ) else (
      echo ERROR: LUA_VER=%LUA_VER% is not a valid version, use 2.0 or 2.1 1>&2 && exit /b 1
    )
  )
) else (
  {V00CMD}
)
SET LUA_ROOT=%~dp0
SET LUA_ROOT=%LUA_ROOT:~0,-1%
SET LUA_ROOT=%LUA_ROOT:\=/%
SET LJ_SYS=Windows
SET LJ_ARCH=x86
SET LJ_CORE=%LUA_ROOT%/%LJ_VER%/%LJ_SYS%/%LJ_ARCH%
SET LUA_PATH=%LUA_ROOT%/?/init.lua;%LUA_ROOT%/?.lua;%LJ_CORE%/?/init.lua;%LJ_CORE%/?.lua;
SET LUA_CPATH=%LUA_ROOT%/?.dll;%LUA_ROOT%/loadall.dll;
LUA_ROOT="$LUA_ROOT" LUA_PATH="$LUA_PATH" LUA_CPATH="$LUA_CPATH" "%LJ_CORE%/luajit" -l__init %*
]]

local luabinsh = [[
#!/bin/bash
if ! [ -z ${LUA_VER+x} ]; then
  if [ "$LUA_VER" == "2.1" ]; then
    {V21SH}
  elif [ "$LUA_VER" == "2.0" ]; then
    {V20SH}
  else
    echo "ERROR: LUA_VER=$LUA_VER is not a valid version, use 2.0 or 2.1" 1>&2 && exit 1
  fi
else
  {V00SH}
fi
LUA_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ "$(uname)" == "Darwin" ]; then
  LJ_SYS="OSX"
elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
  LJ_SYS="Linux"
else
  echo "ERROR - Unsupported system: ""$(uname -s)" 1>&2 && exit 1
fi
LJ_ARCH="x86"
LJ_CORE="$LUA_ROOT""/""$LJ_VER""/""$LJ_SYS""/""$LJ_ARCH"
LUA_PATH="$LUA_ROOT""/?/init.lua;""$LUA_ROOT""/?.lua;""$LJ_CORE""/?/init.lua;""$LJ_CORE""/?.lua;"
LUA_CPATH="$LUA_ROOT""/?.so;""$LUA_ROOT""/loadall.so;"
"$LJ_CORE""/"luajit -l__init $@
]]

local pkgbincmd = [[
@echo off
SETLOCAL
SET BIN_ROOT=%~dp0
SET BIN_ROOT=%BIN_ROOT:~0,-1%
SET BIN_ROOT=%BIN_ROOT:\=/%
SET LUA_ROOT=%BIN_ROOT%/..
call %LUA_ROOT%/lua.cmd %LUA_ROOT%/{BIN} %*
]]

local pkgbinsh = [[
#!/bin/bash
BIN_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LUA_ROOT="$BIN_ROOT""/.."
source "$LUA_ROOT"/lua "$LUA_ROOT""/""{BIN}" $@
]]

--------------------------------------------------------------------------------
-- This is the non-optional part that modifies package.loaders to allow for our
-- modules to be used on any standard LuaJIT installation, relies only on 
-- package.loaders[*], package.path and package.cpath.
-- Assumes that no one else has modified package.loaders.

local ffi = require 'ffi'

local jos, jarch = jit.os, jit.arch

local loaded       = package.loaded
local searchers    = package.loaders
local luasearcher  = searchers[2]
local cluasearcher = searchers[3]

-- Splits a required-name into the root, the eventual version, and the
-- eventual sub-modules chaining.
local function modprootverspec(s)
  local _, _, r, v, p = s:find(modp_root_ver_spec_fmt)
  if r then    
    return r, v, p
  else
    _, _, r, p = s:find(modp_root_spec_fmt)
    return r, '', p
  end  
end

-- TODO: luasyssearcher(name) ?

-- Tries to load a CLua module with OS and arch dependent specifications, cannot 
-- be done via package.cpath because of splitting between dir and base.
-- TODO: Note that 'name' and 'name.name' correspond to the same file, OK?
local function cluasyssearcher(name)
  local root, ver, spec = modprootverspec(name)
  local dir = ver ~= '' and root..'.'..ver or root
  local base = spec ~= '' and root..'.'..spec or root
  base = base:gsub('%.', '_') -- It's OK to substitute '.' with '_' after '-'.
  -- Char '-' is necessary due to call to luaopen_*.
  return cluasearcher(dir..'.'..jos..'.'..jarch..'.-'..base)  
end

table.insert(searchers, 4, cluasyssearcher)

-- TODO: Document the side effect.
-- As the clua loader loads the library immediately if found, we have to 
-- pre-load the dependencies prior to that or such loading will fail.
local function withinit(searcher)
  return function(name)
    local rootname, vername = modprootverspec(name)
    local initname = rootname..(vername and '.'..vername or '')..'.__init'
    local initf = luasearcher(initname)
    if type(initf) == 'function' then
      initf(name) -- TODO: Document it's called with the same name of module.
    end
    return searcher(name)
  end
end

for i=2,4 do
  searchers[i] = withinit(searchers[i])
end

-- Now package.loaders is:
-- [1] = preload
-- [2] = withinit(lua)
-- [3] = withinit(clua)
-- [4] = withinit(cluasys)
-- [5] = cluaroot
-- TODO: Document.

-- TODO: Cygwin uses 'cyg' instead of 'lib' ?
local function clibpath(name, clib)
  if jos ~= 'Windows' and clib:sub(1, 3) ~= 'lib' then
    clib = 'lib'..clib    
  end
  local cpath = package.cpath
  if jos == 'OSX' then
    cpath = cpath:gsub('%.so', '.dylib')
  end
  return package.searchpath(name..'.'..jos..'.'..jarch..'.'..clib, cpath)
end

-- For pre-loading of dynamic libraries loaded by module, either via explicit 
-- loading via ffi.load() or via implicit loading if the result of ffi.load()
-- or a CLua module depends on dynamic libraries.
-- TODO: Do not unload the module in package.loaded, document.
local function loadclib(name)
  local _, _, clib = name:find('clib_([^.]*)') -- TODO: Check '%.' or '.'.
  local path = clibpath(name, clib)
  return path and ffi.load(path)
end

local rootpath = os.getenv('LUA_ROOT') 
local hostpath = rootpath and rootpath..'/host'

if not hostpath or not io.open(hostpath..'/init/__pkg.lua') then
  -- Stop here, only pkg.loadclib is returned.
  return {
    loadclib = loadclib,
  }
end

--------------------------------------------------------------------------------
-- Optional part: if used then packages must be managed via pkg module only.

local lfs = require 'host.init.__lfs'
local curl -- Loaded lazily to avoid circular dependency issue.

local function T(x, n, t, req)
  if (req or type(x) ~= 'nil') and type(x) ~= t then
    error('argument #'..n..' must be of type "'..t..'", "'..type(x)..'" passed')
  end
end

local function finalize(f, onerr)
  return function(...)
    local ok, err = pcall(f, ...)
    if not ok then
      onerr()
      error(err)
    end
  end
end

local function iow(opt, ...)
  if not opt.silent then
    io.write(...)
  end
end

local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = { }
  for k,v in pairs(t) do 
    o[k] = copy(v) 
  end
  return o
end

local function filter(x, f)
  local y, j = { }, 0
  for i=1,#x do
    if f(x[i]) then
      j = j + 1; y[j] = x[i] 
    end
  end
  return y
end

local function optdefaults(opt)
  opt = opt or { }
  local o = copy(opt)
  local ok, defopt = pcall(dofile, hostpath..'/config.lua')
  if not ok then
    error('error in "host/config.lua": '..defopt)
  end
  for k,v in pairs(defopt) do
    if type(o[k]) == 'nil' then
      o[k] = v
    end
  end
  return o
end

local function maxlen(x, c)
  local len = 0
  for i=1,#x do len = math.max(len, c and #x[i][c] or #x[i]) end
  return len
end

local function fill(s, upto, with)
  with = with or ' '
  return s..(with):rep(upto - #s)
end

local function confirm(opt)
  if opt and opt.noconfirm then
    return true
  end
  local answer
  repeat
    io.write('Confirm (y/n)? ')
    io.flush()
    answer = io.read()
  until answer == 'y' or answer == 'n'
  return answer == 'y'
end

local function dlprogress(pre, post, opt)
  pre = pre or ''
  post = post or ''
  local count = { 0 } 
  return function(tot, now)
    if tot > 0 then
      count[1] = count[1] + 1
      local perc = string.format('%3d', now/tot*100)
      local totk = string.format('%d', tot/1000)
      iow(opt, pre, perc, '% of ', totk, 'KB', post, '\r')
      io.flush()
    end
  end, count
end

local buf_mt = {
  write = function(self, s) -- Never invoked as multi-arguments.
    self._i = self._i + 1
    self._l = self._l + #s
    self._b[self._i] = s
  end,
  to = function(self, f)
    local b = self._b
    for i=1,#b do
      f:write(b[i])
    end
  end,
  len = function(self)
    return self._l
  end,
  __tostring = function(self)
    return table.concat(self._b, '')
  end,
}
buf_mt.__index = buf_mt

local function dlbuf()
  return setmetatable({ _i = 0, _l = 0, _b = { } }, buf_mt)
end

-- TODO: Check failures: 
local function download(addr, fnames, out, opt)
  opt = optdefaults(opt)
  curl = curl or require 'cURL'
  local ce = curl.easy()
  ce:setopt_failonerror(true)
  if opt and opt.proxy then
    ce:setopt_proxy(opt.proxy)
  end
  if opt and opt.proxyauth then
    ce:setopt_proxyuserpwd(opt.proxyauth)
  end
  if type(out) == 'string' then
    ce:setopt_noprogress(false)
    local len = maxlen(fnames)
    iow(opt, 'Downloading:\n')
    for i=1,#fnames do
      local dfname = fnames[i]:gsub(' ', '%20')
      ce:setopt_url(addr..dfname)
      local buf = dlbuf()
      local bar, cbar = dlprogress('+ '..fill(fnames[i], len)..' | ', nil, opt)
      ce:setopt_writefunction(buf)
      ce:setopt_progressfunction(bar)
      ce:perform()
      if cbar[1] == 0 then
        -- Make sure that progress bar is called at least once.
        bar(buf:len(), buf:len())
      end
      iow(opt, '\n') io.flush()
      local f = assert(io.open(out..'/'..fnames[i], 'wb'))
      buf:to(f)
      assert(f:close())
    end
  else
    ce:setopt_url(addr..fnames)
    local buf = dlbuf()
    ce:setopt_writefunction(buf)
    ce:perform()
    return tostring(buf)
  end
end

local function esc(s)
  return '"'..s..'"'
end

local nullpath = jos == 'Windows' and 'nul' or '/dev/null'
local pkgpath = rootpath..'/'..(...):gsub('%.', '/')..'/'
local unzipcmd = esc((jos ~= 'OSX'     and pkgpath..jos..'/' or '')..'unzip')
local chmodcmd = esc((jos == 'Windows' and pkgpath..jos..'/' or '')..'chmod')

local function unzip(inpath, outpath)
  local cmd = unzipcmd..' -qq '..esc(inpath)..' -d '..esc(outpath)
  if os.execute(jos == 'Windows' and esc(cmd) or cmd) ~= 0 then
    error('failed to execute: '..cmd)
  end
end

local function setexecflag(fname)
  -- Useless to capture eventual failures here.
  -- As users might be different use a+x, not (u)+x.
  local cmd = chmodcmd..' a+x '..esc(fname)..' > '..nullpath..' 2>&1'
  os.execute(jos == 'Windows' and esc(cmd) or cmd)
end

-- Do its best to remove everything in a path, no error thrown.
local function emptydir(path)
  if lfs.attributes(path) and lfs.attributes(path).mode == 'directory' then
    for file in lfs.dir(path) do
      if file ~= '.' and file ~= '..' then
        local f = path..'/'..file
        local attr = lfs.attributes(f)
        if attr.mode == 'directory' then
          emptydir(f) -- Recurse.
          lfs.rmdir(f)
        else
          os.remove(f)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
local kaorder = { 
  head  = 1,
  alpha = 2,
  beta  = 3,
  work  = 4,
  rc    = 5,
  ['']  = 6, -- Stable.
  patch = 7, -- Stable.
}

local function specval(n, p, ka, kd, rd)
  return math.max(1, 
    n  ~= '' and 2 or 0, 
    p  ~= '' and 3 or 0, 
    ka ~= '' and 4 or 0, 
    kd ~= '' and 5 or 0,
    rd ~= '' and 6 or 0)
end

-- Split string into its version components.
local function versplit(s)
  local f, l, m, n, p, ka, kd, rd = s:find(ver_components_fmt)
  local mn = tonumber(m)
  local nn = tonumber(n) or 0
  local pn = tonumber(p) or 0
  local kan = ka and kaorder[ka:lower()]
  local kdn = tonumber(kd) or 0
  local rdn = tonumber(rd) or 0
  if f ~= 1 or l ~= #s or s:sub(l, l) == '.' or s:find('%.%.') or s:find('%.%-')
  or not kan then
    error('"'..s..'" is not a valid module version')
  end
  return mn, nn, pn, kan, kdn, rdn, specval(n, p, ka, kd, rd)
end

-- Return true if versions are equal up to the specification level.
local function vereqspec(l, r, spec)
  if not l or not r then return true end
  local lm, ln, lp, lka, lkd, lrd, lspec = versplit(l)
  local rm, rn, rp, rka, rkd, rrd, rspec = versplit(r)
  spec = spec or math.min(lspec, rspec)
  if spec >= 1 and lm  ~= rm  then return false end
  if spec >= 2 and ln  ~= rn  then return false end
  if spec >= 3 and lp  ~= rp  then return false end
  if spec >= 4 and lka ~= rka then return false end
  if spec >= 5 and lkd ~= rkd then return false end
  if spec >= 6 and lrd ~= rrd then return false end
  return true
end

-- Return true if l <= r.
local function vercomp(l, r, strict)
  local lm, ln, lp, lka, lkd, lrd = versplit(l)
  local rm, rn, rp, rka, rkd, rrd = versplit(r)
  if lm ~= rm then
    return lm < rm
  elseif ln ~= rn then
    return ln < rn
  elseif lp ~= rp then
    return lp < rp
  elseif lka ~= rka then
    return lka < rka 
  elseif lkd ~= rkd then
    return lkd < rkd
  else
    if strict then
      return lrd < rrd 
    else
      return lrd <= rrd
    end
  end
end

local function verlt(l, r)
  return vercomp(l, r, true)
end

local function verle(l, r)
  return vercomp(l, r, false)
end

local function vinfosorter(x, y) 
  return not verle(x.version, y.version) 
end

local function isstable(x)
  local _,_,_,ka = versplit(x.version)
  return ka == kaorder[''] or ka == kaorder['patch']
end

local function firstok(version, vinfo, spec)
  for i=1,#vinfo do
    local ver = vinfo[i].version
    -- Ver must be equal up to spec to version, and better or equal in the rest.
    if vereqspec(version, ver, spec) and verle(version, ver) then
      return vinfo[i]
    end
  end
end

local function infobest(repo, name, version, spec)
  spec = spec or 1
  local vinfo = repo[name] or { }
  table.sort(vinfo, vinfosorter)
  local svinfo = filter(vinfo, isstable)
  -- If no version indicated return latest stable or, if not available, latest 
  -- unstable.
  if not version then
    return svinfo[1] or vinfo[1]
  else
    return firstok(version, svinfo, spec) or firstok(version, vinfo, spec)
  end
end

local function hasmod(repo, name)
  if not repo[name] then
    error('cannot find module "'..name..'"')
  end
end

local function infobestchk(repo, name, ver, spec)
  hasmod(repo, name)
  local info = infobest(repo, name, ver, spec)
  if not info then
    error('cannot find matching version of module "'..name..'"')
  end
  return info
end

local function infoinsert(repo, name, info)
  repo[name] = repo[name] or { }
  table.insert(repo[name], info)
  table.sort(repo[name], vinfosorter)
end

--------------------------------------------------------------------------------
-- Load the meta-data given that it can be found.
local function getmeta(fullname)
  local f = luasearcher(fullname..'.__meta')
  return type(f) == 'function' and f(fullname..'.__meta')
end

local function okdeprepo(repo)
  local o = { }
  repeat 
    local rn = 0
    for hname,hvinfo in pairs(repo) do
      for i=#hvinfo,1,-1 do
        local torem = false
        for reqname,reqver in pairs(hvinfo[i].require or { }) do
          if not infobest(repo, reqname, reqver) then         
            torem = torem or { }
            torem[#torem + 1] = reqname..'~'..reqver 
          end
        end
        if torem then
          o[#o + 1] = { hname, hvinfo[i], torem }
          rn = rn + 1
          table.remove(hvinfo, i); if #hvinfo == 0 then repo[hname] = nil end
        end 
      end
    end
  until rn == 0
  return o
end

local function checkrepo(repo, onmissing)
  onmissing = onmissing or error
  local miss = okdeprepo(repo)
  if #miss > 0 then
    for i=1,#miss do
      local mod = miss[i][1]..'~'..miss[i][2].version
      local dep = table.concat(miss[i][3], ', ')
      onmissing(mod..' has unmet dependencies: '..dep)
    end
  end
  return miss
end

local syncedhostrepo = { }

local function writebin(pkgbin, ext, relpath, bin)
  local cmd = pkgbin:gsub('{BIN}', relpath..'/'..bin)
  local fname = rootpath..'/bin/'..bin..ext
  local f = assert(io.open(fname, 'w'..(ext == '' and 'b' or '')))
  f:write(cmd)
  assert(f:close())
  setexecflag(fname)
end

-- Discover all name/version available modules and update the bin directory.
local function updatehostrepo()
  syncedhostrepo = { }
  for mod in lfs.dir(rootpath) do
    if mod ~= "." and mod ~= ".." then
      local rootpathmod = rootpath..'/'..mod
      if lfs.attributes(rootpathmod).mode == 'directory' then
         for ver in lfs.dir(rootpathmod) do
           if ver ~= "." and ver ~= ".." then
              local meta = getmeta(mod..'.'..ver)
              if meta then -- This is a module.
                -- Notice that ver is not used at all for building the repo!
                meta.relative_dir = mod..'/'..ver
                infoinsert(syncedhostrepo, mod, meta)
              end
           end
         end 
      end
    end
  end
  -- Check for bin.
  -- TODO: Make version to be called configurable.
  -- TODO: Perform updating of bin directory only when necessary, i.e. when 
  -- TODO: a package is removed, added, updated or when the preferred version 
  -- TODO: to be called has been modified (NYI).
  emptydir(rootpath..'/bin')
  for name in pairs(syncedhostrepo) do
    local info = infobestchk(syncedhostrepo, name)
    local relpath = info.relative_dir..'/__bin'
    if lfs.attributes(rootpath..'/'..relpath) then
      for bin in lfs.dir(rootpath..'/'..relpath) do
        if bin ~= '.' and bin ~= ".." then
          writebin(pkgbincmd, '.cmd', relpath, bin)
          writebin(pkgbinsh,  '',     relpath, bin)
        end
      end
    end
  end
end

updatehostrepo()
checkrepo(syncedhostrepo)

local function hostrepo()
  return copy(syncedhostrepo)
end

local function webrepo(opt)
  opt = optdefaults(opt)
  if opt.localrepo then
    return dofile(opt.localrepo..'/__repo.lua')
  else
    local repo = download(repoaddr, '__repo.lua', nil, opt)
    repo = assert(loadstring(repo))()
    return repo
  end
end

local function lexlt(x, y)
  return x[1] < y[1]
end

local function rtostr(r)
  local a = { }
  for nam,vinfo in pairs(r) do
    table.sort(vinfo, vinfosorter)
    local ver = { }
    for i=1,#vinfo do ver[i] = vinfo[i].version end    
    local des = vinfo[1].description or ''
    if #des > 80 then
      des = des:sub(1, 78)..'..'
    end
    a[#a + 1] = { nam, des, table.concat(ver, ', ') }
  end
  table.sort(a, lexlt)
  local namlen = maxlen(a, 1)
  local deslen = maxlen(a, 2)
  for i=1,#a do
    local nam, des, ver = unpack(a[i])
    a[i] = '+ '..fill(nam, namlen)..' | '..fill(des, deslen)..' | '..ver
  end
  return table.concat(a, '\n')
end

local function infopkg(repo, name, ver)
  local info = infobestchk(repo, name, ver)
  local req = { }
  for reqn, reqv in pairs(info.require or { }) do
    req[#req + 1] = { reqn, reqv }
  end
  table.sort(req, lexlt)
  for i=1,#req do
    req[i] = table.concat(req[i], '~')
  end
  req = table.concat(req, ', ')
  io.write('Module information:\n')
  io.write('name        : ', name, '\n')
  io.write('version     : ', info.version, '\n')
  io.write('require     : ', req, '\n')
  io.write('description : ', info.description or '', '\n')
  io.write('homepage    : ', info.homepage    or '', '\n')
  io.write('license     : ', info.license     or '', '\n')
end

local updatedpkg = false
local toupdate, performupdate

local function updatepkgmod(opt)
  local hostr, webr = hostrepo(), webrepo(opt)
  if updatedpkg then
    error('Restart LuaJIT to apply changes to module "pkg"')
  else
    local pkghost = infobestchk(hostr, 'pkg')
    local pkgrepo = infobestchk(webr,  'pkg')
    if verlt(pkghost.version, pkgrepo.version) then
      io.write('Updated version of module "pkg" is available, updating:\n')
      local addr, remr = { }, { }
      toupdate('pkg', hostr, webr, addr, remr)
      updatedpkg = performupdate(opt, hostr, addr, remr)
      if updatedpkg then
        error('Restart LuaJIT to apply changes to module "pkg"')
      else
        error('Module "pkg" must be updated')
      end
    end
  end
  return hostr, webr
end

local function search(repo, name)
  name = name:lower()
  local match = { }
  for n,v in pairs(repo) do
    -- TODO: I'm checking only the last one.
    local desc = v[1].description or ''
    if n:lower():find(name, 1, true) or desc:lower():find(name, 1, true) then
      match[n] = v
    end
  end
  return match
end

local function status(name, ver)
  T(name, 1, 'string') T(ver, 2, 'string')
  name = name or '?'
  local hostr = hostrepo()
  if name == '?' then
    io.write('Installed modules:\n', rtostr(hostr), '\n')
  elseif name:sub(1, 1) == '?' then
    io.write('Installed modules:\n', rtostr(search(hostr, name:sub(2))), '\n')
  else
    infopkg(hostr, name, ver)
  end
end

local function available(name, ver, opt)
  T(name, 1, 'string') T(ver, 2, 'string') T(opt, 3, 'table')
  name = name or '?'
  opt = optdefaults(opt)
  local _, webr = updatepkgmod(opt)
  if name == '?' then
    io.write('Available modules:\n', rtostr(webr), '\n')
  elseif name:sub(1, 1) == '?' then
    io.write('Available modules:\n', rtostr(search(webr, name:sub(2))), '\n')
  else
    infopkg(webr, name, ver)
  end
end

--------------------------------------------------------------------------------
local function findinit(name)
  local errs = { }
  for _, searcher in ipairs(searchers) do
    local f = searcher(name)
    if type(f) == 'function' then
      return f
    elseif type(f) == 'string' then
      errs[#errs + 1] = f
    end
  end
  error("module '"..name.."' not found"..table.concat(errs))
end

local sentinel = function() end

-- Pre-loading of dynamic libraries loaded by module, either via explicit
-- loading via ffi.load() or via implicit loading if the result of ffi.load()
-- or a CLua module depends on dynamic libraries.
-- TODO: Do not unload the module in package.loaded, document!
local function requirefull(name, plainname)
  plainname = plainname or name
  local p = loaded[name]
  if p then
    if p == sentinel then
      error("loop or previous error loading module '"..name..'"')
    end
    return p
  end
  local init = findinit(name)
  loaded[name] = sentinel
  -- Load the module.
  local res = init(name)
  -- Module() or others in init(name) might set loaded[name] or,
  -- in the case of versioned modules, loaded[plainname].
  if res then
    loaded[name] = res
  elseif loaded[plainname] then
    -- No problem with module() here: contains a check to avoid conflicts.
    loaded[name] = loaded[plainname]
  end
  if loaded[name] == sentinel then
    loaded[name] = true
  end
  return loaded[name]
end

local reqstack = { }

-- Cannot simply modify package.loaders as for versioned modules package.loaded
-- must *not* be set equal to the (unversioned) module name.
local function requirever(name, ver, opt)
  T(name, 1, 'string', true) T(ver, 2, 'string') T(opt, 3, 'table')
  -- 0: Give priority to versioned modules as module() or others might set
  --    loaded[name] breaking the 'load correct version' paradigm.
  local hostr = hostrepo()
  local rootname, _, specname = modprootverspec(name)
  if hostr[rootname] then -- Requiring a versioned module.
    opt = optdefaults(opt)
    if not ver then
      -- 1V: check if calling from a module which has meta info, if so set
      --     version.
      local rootfrom, verfrom = modprootverspec(reqstack[#reqstack - 1] or '')
      if rootfrom then -- The require call come from a module.
        local meta = getmeta(rootfrom..(verfrom and '.'..verfrom or ''))
        if meta then -- And the module has versioning info.
          if rootname ~= rootfrom then
            if not (meta.require and meta.require[rootname]) then
              if rootname ~= 'pkg' then
                iow(opt, 'WARN: module "'..rootfrom..'" is missing version '
                       ..'info for dependency "'..rootname..'"\n')
              end
            else
              ver = meta.require[rootname]
            end
          else
            ver = meta.version
          end
        end
      end
    end
    -- 2V: check best matching module.
    local info = infobestchk(hostr, rootname, ver)
    -- 3V: return versioned module.  
    local matchver = topath(info.version)
    local fullname = rootname..'.'..matchver
    if specname ~= '' then
      fullname = fullname..'.'..specname
    end
    return requirefull(fullname, name)
  else
    -- 1NV: simply return require as usual.
    return requirefull(name)
  end
end

-- TODO: Only require is traced: dofile() and loadfile() are not, document!
_G.require = function(name, ver, opt)
  reqstack[#reqstack + 1] = name
  local ok, mod = xpcall(requirever, debug.traceback, name, ver, opt)
  reqstack[#reqstack] = nil
  if not ok then
    print(mod)
    os.exit(1)
  end
  return mod
end

--------------------------------------------------------------------------------
local function updateinit1(fn, fv)
  local f = assert(io.open(hostpath..'/init/__'..fn..'.lua', 'w'))
  f:write('return require "'..fn..'.'..topath(fv)..'"\n')
  assert(f:close())
end

-- TODO: Add safety net, it's the only function that might leave system in 
-- TODO: inconsistent state.
local function updateinit(hostr, addr, remr)
  addr = addr or { }
  remr = remr or { }
  if addr.pkg or remr.pkg then 
    updateinit1('pkg', infobestchk(hostr, 'pkg').version) -- MODIFICATION.
  end
  if addr.lfs or remr.lfs then
    updateinit1('lfs', infobestchk(hostr, 'lfs').version) -- MODIFICATION.
  end
  if addr.luajit or remr.luajit then
    local lua20 = infobest(hostr, 'luajit', '2.0',      2)
    local lua21 = infobest(hostr, 'luajit', '2.1.head', 2)
    local lua20ver = lua20 and 'luajit/'..topath(lua20.version)
    local lua21ver = lua21 and 'luajit/'..topath(lua21.version)
    local vermap = {
      V20CMD = lua20ver and 'SET LJ_VER='..lua20ver or
               'echo ERROR: luajit 2.0 not installed 1>&2 && exit /b 1',
      V21CMD = lua21ver and 'SET LJ_VER='..lua21ver or
               'echo ERROR: luajit 2.1 not installed 1>&2 && exit /b 1',
      V20SH = lua20ver and 'LJ_VER="'..lua20ver..'"' or
               'echo "ERROR: luajit 2.0 not installed" 1>&2 && exit 1',
      V21SH = lua21ver and 'LJ_VER="'..lua21ver..'"' or
               'echo "ERROR: luajit 2.1 not installed" 1>&2 && exit 1',      
    }
    vermap.V00CMD = lua21ver and vermap.V21CMD or vermap.V20CMD
    vermap.V00SH = lua21ver and vermap.V21SH or vermap.V20SH
    local fcmd = assert(io.open(rootpath..'/lua.cmd', 'w'))
    fcmd:write((luabincmd:gsub('{(.-)}', vermap)))
    assert(fcmd:close())
    local fsh = assert(io.open(rootpath..'/lua', 'wb'))
    fsh:write((luabinsh:gsub('{(.-)}', vermap)))
    assert(fsh:close())
    setexecflag(rootpath..'/lua')
  end
end

local function filenames(repo)  
  local fns, fvs = { }, { }
  for name,vinfo in pairs(repo) do
    for i=1,#vinfo do
      table.insert(fns, name)
      table.insert(fvs, vinfo[i].version)
    end
  end
  return fns, fvs
end

local function pkgsdownload(fns, fvs, opt)
  local todown = { }
  for i=1,#fns do
    local fname = fns[i]..'~'..fvs[i]..'.zip'
    local pkgdir = opt.localrepo or hostpath..'/pkg'
    local f = io.open(pkgdir..'/'..fname)
    if not f then
      table.insert(todown, fname)
    else
      f:close()
    end
  end
  if #todown > 0 then
    download(repoaddr, todown, hostpath..'/pkg', opt)
  end
end

local function pkgsunzip(fns, fvs, opt)
  local pkgdir = opt.localrepo or hostpath..'/pkg'
  for i=1,#fns do
    unzip(pkgdir..'/'..fns[i]..'~'..fvs[i]..'.zip', hostpath..'/tmp')
  end
end

local function pkgsinstall(fns, fvs)
  for i=1,#fns do
    local fn, fv = fns[i], fvs[i]
    if not lfs.attributes(rootpath..'/'..fn) then
      assert(lfs.mkdir(rootpath..'/'..fn))
    end
    local targetpath = rootpath..'/'..fn..'/'..topath(fv)
    if lfs.attributes(targetpath) then -- Should never happen.
      error('path "'..targetpath..'" already exists')
    end
    assert(os.rename(hostpath..'/tmp/'..fn, targetpath)) -- MODIFICATION.
  end
end

local function pkgsremove(fns, fvs)
  for i=1,#fns do
    local fn, fv = fns[i], fvs[i]
    local targetpath = rootpath..'/'..fn..'/'..topath(fv)
    if not lfs.attributes(targetpath) then -- Should never happen.
      error('path "'..targetpath..'" does not exist')
    end
    local backuppath = hostpath..'/tmp/'..fn..'_'..topath(fv)
    assert(os.rename(targetpath, backuppath)) -- MODIFICATION.
    lfs.rmdir(rootpath..'/'..fn) -- Only if empty MODIFICATION.
  end
end

-- Modify hostr so that it includes the new modules.
local function toadd(name, version, hostr, webr, addr)
  -- If suitable version already installed (any if version not present) or to be
  -- installed => stop:
  if infobest(hostr, name, version)
  or infobest(addr,  name, version) then
    return
  end
  -- If no suitable version available (any if version not present) => error:
  local info = infobestchk(webr, name, version)
  -- Add module.
  infoinsert(addr, name, info)
  infoinsert(hostr, name, info)
  -- Repeat for all required modules as well.
  for reqname, reqver in pairs(info.require or { }) do
    toadd(reqname, reqver, hostr, webr, addr)
  end
end

local performadd = finalize(function(hostr, addr, opt)
  emptydir(hostpath..'/tmp')
  local fns, fvs = filenames(addr)
  pkgsdownload(fns, fvs, opt)
  pkgsunzip(fns, fvs, opt)
  pkgsinstall(fns, fvs, opt)
  updateinit(hostr, addr, nil)
  updatehostrepo()
end, updatehostrepo)

local function add(name, version, opt)
  T(name, 1, 'string', true) T(version, 2, 'string') T(opt, 3, 'table')
  opt = optdefaults(opt)
  local hostr, webr = updatepkgmod(opt)
  local addr = { }
  toadd(name, version, hostr, webr, addr)
  if next(addr) then
    iow(opt, 'Installing matching module and its requirements:\n')
    iow(opt, rtostr(addr), '\n')
    if confirm(opt) then
      performadd(hostr, addr, opt)
      iow(opt, 'Done\n')
    end
  else
    iow(opt, 'Module already installed\n')
  end  
end

local performremove = finalize(function(hostr, remr, opt)
  emptydir(hostpath..'/tmp')
  local fns, fvs = filenames(remr)
  pkgsremove(fns, fvs, opt)
  updateinit(hostr, nil, remr)
  updatehostrepo()
end, updatehostrepo)

local function remove(name, version, opt)
  T(name, 1, 'string', true) T(version, 2, 'string') T(opt, 3, 'table')
  opt = optdefaults(opt)
  local hostr = hostrepo()
  hasmod(hostr, name)
  -- Remove all matching modules.
  local remr = { }
  local vinfo = hostr[name]
  for i=#vinfo,1,-1 do
    if vereqspec(version, vinfo[i].version) then
      infoinsert(remr, name, vinfo[i])
      table.remove(vinfo, i); if #vinfo == 0 then hostr[name] = nil end
    end
  end
  if not remr[name] then
    error('no matching version of module "'..name..'" is installed')
  end
  -- And all the modules whose dependencies are now not satisfied, and so on...
  local tormr = okdeprepo(hostr)
  for i=1,#tormr do
    infoinsert(remr, tormr[i][1], tormr[i][2])
  end
  -- Check no one of the core modules will be removed.
  for cname,_ in pairs(coremodule) do
    if not hostr[cname] then
      error('operation results in the removal of core module "'..cname..'"')
    end
  end
  iow(opt, 'Removing matching modules and modules that depend on them:\n')
  iow(opt, rtostr(remr), '\n')
  if confirm(opt) then
    performremove(hostr, remr, opt)
    iow(opt, 'Done\n')
  end
end

toupdate = function(name, hostr, webr, addr, remr)
  hasmod(hostr, name)
  if not webr[name] then
    return
  end
  local vinfo, tmpr = hostr[name], { }
  for i=#vinfo,1,-1 do
    local candidate = infobest(webr, name, vinfo[i].version)
    if candidate and candidate.version ~= vinfo[i].version
    and (isstable(candidate) or not isstable(vinfo[i])) then
      -- Updated module is guaranteed to satisfy any dependency that the 
      -- obsoleted one did, hence we can just remove it without checks.
      infoinsert(remr, name, vinfo[i])
      -- No need to check hostr[name] empty, call to toadd() later.
      table.remove(vinfo, i)
      -- Cannot add in this pass the new module via toadd() as it would modify 
      -- vinfo that I am traversing.
      table.insert(tmpr, candidate)
    end
  end
  for i=1,#tmpr do
    -- Takes care of new dependencies and no module is added twice.
    toadd(name, tmpr[i].version, hostr, webr, addr)
  end
end

performupdate = function(opt, hostr, addr, remr)
  if next(addr) then
    iow(opt, 'Installing updated modules and their requirements:\n')
    iow(opt, rtostr(addr), '\n')
    iow(opt, 'Removing obsoleted modules:\n')
    iow(opt, rtostr(remr), '\n')
    if confirm(opt) then
      performadd(hostr, addr, opt)
      performremove(hostr, remr, opt)
      iow(opt, 'Done\n')
      return true
    end
  else
    iow(opt, 'No module to update\n')
  end
  return false
end

local function update(opt)
  T(opt, 1, 'table')
  opt = optdefaults(opt)
  local hostr, webr = updatepkgmod(opt)
  local addr, remr = { }, { }
  for hname, _ in pairs(hostr) do
    toupdate(hname, hostr, webr, addr, remr)
  end
  performupdate(opt, hostr, addr, remr)
end

--------------------------------------------------------------------------------

return {
  loadclib  = loadclib,

  available = available,
  status    = status,
  add       = add,
  remove    = remove,
  update    = update,

  util = {
    verlt       = verlt,
    verle       = verle,
    versplit    = versplit,
    emptydir    = emptydir,
    download    = download,
    modzrootver = modzrootver,
    topath      = topath,
    tover       = tover,
    rtostr      = rtostr,
    infoinsert  = infoinsert,
    infobest    = infobest,
    hostrepo    = hostrepo,
    okdeprepo   = okdeprepo,
    checkrepo   = checkrepo,
  }
}
