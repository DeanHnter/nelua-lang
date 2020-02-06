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

local compiler = {}

local function get_compile_args(cfile, binfile, compileopts)
  local compiler_flags = cdefs.compilers_flags[config.cc] or cdefs.compiler_base_flags
  local cflags = sstream(compiler_flags.cflags_base)
  cflags:add(' ')
  cflags:addlist(compiler_flags.cflags_warn, ' ')
  cflags:add(' ', config.release and compiler_flags.cflags_release or compiler_flags.cflags_debug)
  if config.cflags then
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
  local env = { cfile = cfile, binfile = binfile, cflags = cflags:tostring(), cc = config.cc }
  return pegger.substitute('$(cc) -o "$(binfile)" "$(cfile)" $(cflags)', env)
end

local last_ccinfos = {}
function compiler.get_cc_info()
  local last_ccinfo = last_ccinfos[config.cc]
  if last_ccinfo then return last_ccinfo end
  local cccmd = string.format('%s -v', config.cc)
  local ok, ret, stdout, stderr = executor.execex(cccmd)
  except.assertraisef(ok and ret == 0, "failed to retrieve compiler information: %s", stderr)
  local text = stderr and stderr ~= '' and stderr or stdout
  local ccinfo = {
    target = text:match('Target: ([-_%w]+)'),
    thread_model = text:match('Thread model: ([-_%w]+)'),
    version = text:match('version ([.%d]+)'),
    name = text:match('([-_%w]+) version') or config.cc,
    exe = config.cc,
    text = text
  }
  last_ccinfos[config.cc] = ccinfo
  return ccinfo
end

function compiler.get_c_defines(headers)
  local tmpname = fs.gettmpname()
  local code = {}
  for _,header in ipairs(headers) do
    table.insert(code, '#include ' .. header)
  end
  fs.writefile(tmpname, table.concat(code))
  local cccmd = string.format('%s -x c -E -dM %s', config.cc, tmpname)
  local ok, ret, stdout, ccinfo = executor.execex(cccmd)
  fs.deletefile(tmpname)
  except.assertraisef(ok and ret == 0, "failed to retrieve compiler information: %s", ccinfo or '')
  return pegger.parse_c_defines(stdout)
end

function compiler.compile_code(ccode, outfile, compileopts)
  local cfile = outfile .. '.c'
  local ccinfo = compiler.get_cc_info().text
  local ccmd = get_compile_args(cfile, outfile, compileopts)

  -- file heading
  local hash = stringer.hash(string.format("%s%s%s", ccode, ccinfo, ccmd))
  local heading = string.format(
[[/* This file was auto generated by Nelua. */
/* Compile command: %s */
/* Compile hash: %s */

]], ccmd, hash)
  local sourcecode = heading .. ccode

  -- check if write is actually needed
  local current_sourcecode = fs.tryreadfile(cfile)
  if not config.no_cache and current_sourcecode and current_sourcecode == sourcecode then
    if not config.quiet then console.info("using cached generated " .. cfile) end
    return cfile
  end

  fs.ensurefilepath(cfile)
  fs.writefile(cfile, sourcecode)
  if not config.quiet then console.info("generated " .. cfile) end

  return cfile
end

function compiler.compile_binary(cfile, outfile, compileopts)
  local binfile = outfile

  local ccinfo = compiler.get_cc_info()
  if ccinfo.target and (ccinfo.target:match('windows') or ccinfo.target:match('mingw')) then --luacov:disable
    binfile = outfile .. '.exe'
  end --luacov:enable

  -- if the file with that hash already exists skip recompiling it
  if not config.no_cache then
    local cfile_mtime = fs.getfiletime(cfile)
    local binfile_mtime = fs.getfiletime(binfile)
    if cfile_mtime and binfile_mtime and cfile_mtime <= binfile_mtime then
      if not config.quiet then console.info("using cached binary " .. binfile) end
      return binfile
    end
  end

  fs.ensurefilepath(binfile)

  -- generate compile command
  local cccmd = get_compile_args(cfile, binfile, compileopts)
  if not config.quiet then console.info(cccmd) end

  -- compile the file
  local success, status, stdout, stderr = executor.execex(cccmd)
  except.assertraisef(success and status == 0,
    "C compilation for '%s' failed:\n%s", binfile, stderr or '')

  if stderr then
    io.stderr:write(stderr)
  end

  return binfile
end

function compiler.get_run_command(binaryfile, runargs)
  return fs.abspath(binaryfile), tabler.copy(runargs)
end

return compiler
