local unpack = string.unpack

-- ldump.c:73:DumpString. Three formats.
-- * (char)0. No string. Occurs when debug info is missing, e.g. stripped dump
-- or nameless locals.
-- * (char)255, (size_t)size, char[size-1]. Used for strings of at least 254
-- characters, where the size (including trailing 0) won't fit in a byte.
-- * (char)size, char[size-1]. Strings of at most 253 characters.
-- The encoded size includes space for a trailing 0 which isn't actually in the
-- dump, so none of these unpack cleanly with the 's' format either...
local function parse_string (s, y)
	local len, x = unpack("B", s, y)
	if len == 0 then
		return nil, x
	elseif len == 255 then
		len, x = unpack("T", s, x)
	end
	return unpack("c"..(len-1), s, x)
end

-- ldump.c:90:DumpCode. (int)sizecode, Instruction[sizecode].
-- Instruction is a typedef for an unsigned integer (int or long) with at least
-- 32 bits; this is almost certainly 4 bytes, but theoretically doesn't have to
-- be, so we pass the format in as an argument.
-- lopcodes.h:13. On the 5.3 VM, instructions are 32-bit integers packing
-- opcode:6, A:8, C:9, B:9 bits. (Yes, C is between A and B...)
-- lopcodes.h:178:OP_GETTABUP,/*       A B C   R(A) := UpValue[B][RK(C)]
-- lopcodes.h:181:OP_SETTABUP,/*       A B C   UpValue[A][RK(B)] := RK(C)
-- A global access compiles down to a table access to the upvalue holding the
-- closed-over value of _ENV. Unfortunately, at this point, we don't actually
-- know which upvalue (if any!) is _ENV, so we have to mark down every upvalue
-- table access as suspicious.
-- Returns a sequence of {upvalue, instruction index, is write, table index}
-- tuples; of these, only the upvalue is strictly necessary:
-- * instruction index is used to look line numbers up from debug info
-- * table index can be looked up in the constants table for the name accessed
local function parse_code (s, x, ins_fmt)
	local OP_GETTABUP, OP_SETTABUP = 6, 8
	local d, v = {}
	v, x = unpack("i", s, x)

	for j=1,v do
		v, x = unpack(ins_fmt, s, x)
		local o, b = v & 63, v>>23 & 511
		if o == OP_GETTABUP then
			d[#d+1] = {b, j, false, v>>14 & 511}
		elseif o == OP_SETTABUP then
			d[#d+1] = {v>>6 & 255, j, true, b}
		end
	end

	return d, x
end

-- ldump.c:98:DumpConstants. (int)sizek, Various[sizek].
-- This is a nasty format whose size can't be computed without parsing.
-- "Various" comprises five formats of note:
-- * (char)LUA_TNIL==0.
-- * (char)LUA_TBOOLEAN==1, char.
-- * (char)LUA_TNUMFLT==3, lua_Number.
-- * (char)LUA_TNUMINT==19, lua_Integer.
-- * (char)LUA_TSHRSTR==4 or LUA_TLNGSTR==20, DumpString.
-- Only string constants *really* matter, since those are generated by "real"
-- global accesses; the others only occur on false-positives generated by
-- directly indexing _ENV. Of course, those will generate misleading reports.
local function parse_constants (s, x)
	local k, v = {}
	v, x = unpack("i", s, x)

	for j=1,v do
		v, x = unpack("B", s, x)
		if v == 0 then -- nil
			v = "nil"
		elseif v == 1 then -- boolean
			v, x = unpack("B", s, x)
			v = tostring(v ~= 0)
		elseif v == 3 then -- number (numflt)
			v, x = unpack("n", s, x)
		elseif v == 19 then -- number (numint)
			v, x = unpack("j", s, x)
		elseif v == 4 or v == 20 then -- string (shrstr/lngstr)
			v, x = parse_string(s, x)
		else
			assert(false, "bad ttype "..v.." at byte "..x)
		end
		k[j] = v
	end

	return k, x
end

-- ldump.c:137:DumpUpvalues.
local function parse_upvalues (s, x, env_index)
	local v, z
	v, x = unpack("i", s, x)
	z = x + 2*v
	if not env_index then
		return nil, z
	end
	for j=1,v do
		v, x = unpack(">i2", s, x)
		if v == env_index then
			return j-1, z
		end
	end

	return nil, z
end

-- ldump.c:147:DumpDebug.
-- (int)sizelineinfo, (int[sizelineinfo])lineinfo,
-- (int)sizelocvars, locvars, (int)sizeupvalues, upvalues.
-- This section is totally zeroed out for stripped dumps.
-- Line numbers are useful to report if available.
local function parse_debug (s, x)
	local lineinfo, locvars, upvalues, v = {}, nil, {}

	v, x = unpack("i", s, x)
	for j=1,v do
		lineinfo[j], x = unpack("i", s, x)
	end

	v, x = unpack("i", s, x)
	for j=1,v do
		local varname, startpc, endpc
		varname, x = parse_string(s, x)
		startpc, endpc, x = unpack("ii", s, x)
		--locvars[j] = {varname, startpc, endpc}
	end

	v, x = unpack("i", s, x)
	for j=1,v do
		upvalues[j], x = parse_string(s, x)
	end

	return lineinfo, locvars, upvalues, x
end

-- ldump.c:166:DumpFunction.
-- [DumpString]source, (int)linedefined, (int)lastlinedefined,
-- (char)numparams, (char)is_vararg, (char)maxstacksize,
-- DumpCode, DumpConstants, DumpUpvalues, DumpProtos, DumpDebug.
local function parse_function (cb, s, x, ins_fmt, env_index, parent)
	local source, linedefined, lastlinedefined
	source, x = parse_string(s, x)
	source = source or parent
	linedefined, lastlinedefined, x = unpack("iixxx", s, x)

	if linedefined == 0 then
		-- (char)instack==1, (char)idx==0. See parse_upvalues.
		env_index = 256
	end

	local candidates, constants
	candidates, x = parse_code(s, x, ins_fmt)
	constants, x = parse_constants(s, x)
	env_index, x = parse_upvalues(s, x, env_index)

	local nprotos
	nprotos, x = unpack("i", s, x)
	for j=1,nprotos do
		x = parse_function(cb, s, x, ins_fmt, env_index, source)
	end

	local debug_lineinfo, debug_locvars, debug_upvalues
	debug_lineinfo, debug_locvars, debug_upvalues, x = parse_debug(s, x)

	if env_index then
		for j=1,#candidates do
			local a = candidates[j]
			if a[1] == env_index then
				local line = debug_lineinfo[a[2]]
				if line then
				elseif linedefined == 0 then
					line = "main"
				else
					line = linedefined .. "-" .. lastlinedefined
				end
				local name = constants[a[4]-255] or "(not constant)"
				cb(name, a[3], source or "=stripped", line)
			end
		end
	end

	return x
end

-- ldump.c:184:DumpHeader.
-- "\x1bLua"[:4], (char)LUAC_VERSION==0x53, (char)LUAC_FORMAT==0,
-- LUAC_DATA=="\x19\x93\r\n\x1a\n"[:6],
-- (char)sizeof(int), (char)sizeof(size_t), (char)sizeof(Instruction),
-- (char)sizeof(lua_Integer), (char)sizeof(lua_Number),
-- (lua_Integer)LUAC_INT==0x5678, (lua_Number)LUAC_NUM==370.5.
-- Additionally, skip an extra byte: ldump.c:211. (char)sizeupvalues.
local function parse_header (s)
	local sig, ver, fmt, lit, isz, int, num, x = unpack("c4BBc6xxBxxjnx", s)
	assert(sig == "\x1bLua", "not a dump")
	assert(ver == 0x53 and fmt == 0, "not a standard 5.3 dump")
	assert(lit == "\x19\x93\r\n\x1a\n", "mangled dump (conversions?)")
	assert(int == 0x5678, "mangled dump (wrong-endian?)")
	assert(num == 370.5, "mangled dump (floats broken?)")
	return "I"..isz, x
end

local function check_dump (s, cb)
	local ins_fmt, x = parse_header(s)
	return parse_function(cb, s, x, ins_fmt)
end

local function strict_mode (env, fun)
	if not fun then
		fun = string.dump(debug.getinfo(2, "f").func)
	elseif type(fun) == "function" then
		fun = string.dump(fun)
	end
	env = env or _ENV
	local accum = {}
	check_dump(fun, function (key, is_write, source, line)
		if not env[key] then
			source = source:sub(2)
			local action = is_write and "write: " or "read: "
			accum[#accum+1] = source..":"..line..": global "..action..key
		end
	end)
	if #accum > 0 then
		accum[0] = "unexpected globals"
		error(table.concat(accum, "\n\t", 0), 2)
	end
end

strict_mode()
return strict_mode
