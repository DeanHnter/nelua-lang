local pegger = require 'nelua.utils.pegger'
local stringer = require 'nelua.utils.stringer'
local fs = require 'nelua.utils.fs'
local except = require 'nelua.utils.except'
local executor = require 'nelua.utils.executor'
local tabler = require 'nelua.utils.tabler'
local sstream = require 'nelua.utils.sstream'
local console = require 'nelua.utils.console'
local config = require 'nelua.configer'.get()
local cdefs = require 'nelua.cdefs'
local memoize = require 'nelua.utils.memoize'

local compiler = {}

local function get_compiler_cflags(compileopts)
  local compiler_flags = cdefs.compilers_flags[config.cc] or cdefs.compiler_base_flags
  local cflags = sstream(compiler_flags.cflags_base)
  --luacov:disable
  if config.release then
    cflags:add(' ', compiler_flags.cflags_release)
    if config.cflags_release then
      cflags:add(' ', config.cflags_release)
    end
  else
    cflags:add(' ', compiler_flags.cflags_debug)
    if config.cflags_debug then
      cflags:add(' ', config.cflags_debug)
    end
  end
  if config.shared then
    cflags:add(' -shared -fPIC')
  elseif config.static then
    cflags:add(' -c')
  end
  --luacov:enable
  if #config.cflags > 0 then
    cflags:add(' ', config.cflags)
  end
  if #compileopts.cflags > 0 then
    cflags:add(' ')
    cflags:addlist(compileopts.cflags, ' ')
  end
  if #compileopts.ldflags > 0 then
    cflags:add(' -Wl,')
    cflags:addlist(compileopts.ldflags, ',')
  end
  if #compileopts.linklibs > 0 then
    cflags:add(' -l')
    cflags:addlist(compileopts.linklibs, ' -l')
  end
  return cflags:tostring()
end

local function get_compile_args(cfile, binfile, cflags)
  local env = { cfile = cfile, binfile = binfile, cflags = cflags, cc = config.cc }
  return pegger.substitute('$(cc) -o "$(binfile)" "$(cfile)" $(cflags)', env)
end

local function get_cc_info(cc)
  local cccmd = string.format('%s -v', cc)
  local ok, ret, stdout, stderr = executor.execex(cccmd)
  except.assertraisef(ok and ret == 0, "failed to retrieve compiler information: %s", stderr)
  local text = stderr and stderr ~= '' and stderr or stdout
  local ccinfo = {
    target = text:match('Target: ([-_%w]+)'),
    thread_model = text:match('Thread model: ([-_%w]+)'),
    version = text:match('version ([.%d]+)'),
    name = text:match('([-_%w]+) version') or cc,
    exe = cc,
    text = text,
  }
  ccinfo.is_emscripten = text:match('Emscripten') ~= nil
  if ccinfo.target then
    ccinfo.is_windows = ccinfo.target:match('windows') or ccinfo.target:match('mingw')
  end
  return ccinfo
end
get_cc_info = memoize(get_cc_info)

function compiler.get_cc_info()
  return get_cc_info(config.cc)
end

local function get_cc_defines(cc, ...)
  local tmpname = fs.tmpname()
  local code = {}
  for i=1,select('#', ...) do
    local header = select(i, ...)
    table.insert(code, '#include ' .. header)
  end
  fs.ewritefile(tmpname, table.concat(code))
  local cccmd = string.format('%s -x c -E -dM %s', cc, tmpname)
  local ok, ret, stdout, ccinfo = executor.execex(cccmd)
  fs.deletefile(tmpname)
  except.assertraisef(ok and ret == 0, "failed to retrieve compiler information: %s", ccinfo or '')
  return pegger.parse_c_defines(stdout)
end
get_cc_defines = memoize(get_cc_defines)

function compiler.get_cc_defines(...)
  return get_cc_defines(config.cc, ...)
end

function compiler.compile_code(ccode, outfile, compileopts)
  local cfile = outfile .. '.c'
  local ccinfo = compiler.get_cc_info().text
  local cflags = get_compiler_cflags(compileopts)
  local ccmd = get_compile_args(cfile, outfile, cflags)

  -- file heading
  local hash = stringer.hash(string.format("%s%s%s", ccode, ccinfo, ccmd))
  local heading = string.format(
[[/* This file was auto generated by Nelua. */
/* Compile command: %s */
/* Compile hash: %s */

]], ccmd, hash)
  local sourcecode = heading .. ccode

  -- check if write is actually needed
  local current_sourcecode = fs.readfile(cfile)
  if not config.no_cache and current_sourcecode and current_sourcecode == sourcecode then
    if not config.quiet then console.info("using cached generated " .. cfile) end
    return cfile
  end

  fs.eensurefilepath(cfile)
  fs.ewritefile(cfile, sourcecode)
  if not config.quiet then console.info("generated " .. cfile) end

  return cfile
end

local function detect_binary_extension(ccinfo)
  --luacov:disable
  if ccinfo.is_emscripten then
    return '.html'
  elseif ccinfo.is_windows then
    if config.shared then
      return '.dll'
    elseif config.static then
      return '.a'
    else
      return '.exe', true
    end
  else
    if config.shared then
      return '.so'
    elseif config.static then
      return '.a'
    else
      return '', true
    end
  end
  --luacov:enable
end

function compiler.compile_static_library(objfile, outfile)
  local ar = config.cc:gsub('[a-z]+$', 'ar')
  local arcmd = string.format('%s rcs %s %s', ar, outfile, objfile)
  if not config.quiet then console.info(arcmd) end

  -- compile the file
  local success, status, stdout, stderr = executor.execex(arcmd)
  except.assertraisef(success and status == 0,
    "static library compilation for '%s' failed:\n%s", outfile, stderr or '')

  if stderr then
    io.stderr:write(stderr)
  end
end

function compiler.compile_binary(cfile, outfile, compileopts)
  local cflags = get_compiler_cflags(compileopts)
  local ccinfo = compiler.get_cc_info()
  local binext, isexe = detect_binary_extension(ccinfo)
  local binfile = outfile
  if not stringer.endswith(binfile, binext) then binfile = binfile .. binext end

  -- if the file with that hash already exists skip recompiling it
  if not config.no_cache then
    local cfile_mtime = fs.getmodtime(cfile)
    local binfile_mtime = fs.getmodtime(binfile)
    if cfile_mtime and binfile_mtime and cfile_mtime <= binfile_mtime then
      if not config.quiet then console.info("using cached binary " .. binfile) end
      return binfile, isexe
    end
  end

  fs.eensurefilepath(binfile)

  local midfile = binfile
  if config.static then -- compile to an object first for static libraries
    midfile = binfile:gsub('.[a-z]+$', '.o')
  end
  -- generate compile command
  local cccmd = get_compile_args(cfile, midfile, cflags)
  if not config.quiet then console.info(cccmd) end

  -- compile the file
  local success, status, stdout, stderr = executor.execex(cccmd)
  except.assertraisef(success and status == 0,
    "C compilation for '%s' failed:\n%s", binfile, stderr or '')

  if stderr then
    io.stderr:write(stderr)
  end

  if config.static then
    compiler.compile_static_library(midfile, binfile)
  end

  return binfile, isexe
end

function compiler.get_gdb_version() --luacov:disable
  local ok, ret, stdout, stderr = executor.execex(config.gdb .. ' -v')
  if ok and ret and stdout:match("GNU gdb") then
    local version = stdout:match('%d+%.%d+')
    return version
  end
end --luacov:enable

function compiler.get_run_command(binaryfile, runargs)
  if config.debug then --luacov:disable
    local gdbver = compiler.get_gdb_version()
    if gdbver then
      local gdbargs = {
        '-q',
        '-ex', 'run',
        '-ex', 'bt -frame-info source-and-location',
        '-ex', 'set confirm off',
        '-ex', 'quit',
        binaryfile
      }
      tabler.insertvalues(gdbargs, runargs)
      return config.gdb, gdbargs
    end
  end --luacov:enable

  return fs.abspath(binaryfile), tabler.icopy(runargs)
end

return compiler
