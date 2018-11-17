local unpack = string.unpack

local function parse_string(s, y)
	local len, x = unpack("B", s, y)
	if len == 0 then
		return nil, x
	elseif len == 255 then
		len, x = unpack("T", s, x)
	end
	return unpack("c"..(len-1), s, x)
end

local function parse_code(s, x, i)
	local d, v = {}
	v, x = unpack("i", s, x)

	for j=1,v do
		v, x = unpack(i, s, x)
		local o, b = v & 63, v>>23 & 511
		if o == 6 then -- GETTABUP
			d[#d+1] = {false, b, v>>14 & 511, j}
		elseif o == 8 then -- SETTABUP
			d[#d+1] = {true, v>>6 & 255, b, j}
		end
	end

	return d, x
end

local function parse_constants(s, x)
	local k, v = {}
	v, x = unpack("i", s, x)

	for j=1,v do
		v, x = unpack("B", s, x)
		if v == 0 then -- nil
		elseif v == 1 then -- boolean
			v, x = unpack("B", s, x)
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

local function parse_upvalues(s, x, is_main)
	local v, w, z
	v, x = unpack("i", s, x)
	z = x + 2*v
	for j=1,v do
		v, w, x = unpack("BB", s, x)
		-- (main && v) || (!main && !v) -> main == v
		if w == 0 and is_main == (v ~= 0) then
			return j-1, z
		end
	end
	return nil, z
end

local function parse_debug(s, x)
	local lineinfo, locvars, upvalues, v = {}, {}, {}

	v, x = unpack("i", s, x)
	for j=1,v do
		lineinfo[j], x = unpack("i", s, x)
	end

	v, x = unpack("i", s, x)
	for j=1,v do
		local n, b, e
		n, x = parse_string(s, x)
		b, e, x = unpack("ii", s, x)
		locvars[j] = {n,b,e}
	end

	v, x = unpack("i", s, x)
	for j=1,v do
		upvalues[j], x = parse_string(s, x)
	end

	return lineinfo, locvars, upvalues, x
end

local function check_function(accum, env, s, x, ins_fmt, parent_source)
	local source, linedefined, lastlinedefined
	source, x = parse_string(s, x)
	source = source or parent_source
	linedefined, lastlinedefined, x = unpack("iixxx", s, x)

	local candidates, constants, env_index
	candidates, x = parse_code(s, x, ins_fmt)
	constants, x = parse_constants(s, x)
	env_index, x = parse_upvalues(s, x, linedefined == 0)
	if not env_index then
		accum = nil
	end

	local nprotos
	nprotos, x = unpack("i", s, x)
	for j=1,nprotos do
		x = check_function(accum, env, s, x, ins_fmt, source)
	end

	local debug_lineinfo, debug_locvars, debug_upvalues
	debug_lineinfo, debug_locvars, debug_upvalues, x = parse_debug(s, x)

	if accum then
		local func = source:sub(2)..":"..linedefined.."-"..lastlinedefined
		for j=1,#candidates do
			if candidates[j][2] == env_index then
				local key = constants[candidates[j][3]-255]
				if candidates[j][1] or (key and not env[key]) then
					local action = candidates[j][1] and "write: " or "read: "
					local line = debug_lineinfo[candidates[j][4]]
					local prefix = line and func..":"..line
					accum[#accum+1] = prefix..": global "..action..key
				end
			end
		end
	end

	return x
end

local function check_dump(s, env)
	local sig, ver, lit, isz, int, num, x = unpack("c4<I2=c6xxBxxjnx", s)
	assert(sig == "\x1bLua", "not a dump")
	assert(ver == 0x53, "not a standard 5.3 dump")
	assert(lit == "\x19\x93\r\n\x1a\n", "mangled dump (conversions?)")
	assert(int == 0x5678, "mangled dump (wrong-endian?)")
	assert(num == 370.5, "mangled dump (floats broken?)")

	local accum = {}
	assert(check_function(accum, env or _ENV, s, x, "i"..isz, "") == #s+1)
	return accum
end

local function strict_mode(env, lenient)
	local accum = check_dump(string.dump(debug.getinfo(2, "f").func), env)
	if #accum <= 0 then
		return
	end

	if lenient then
		accum[#accum+1] = ""
		io.stderr:write(table.concat(accum, "\n"))
	else
		accum[0] = "unexpected globals"
		error(table.concat(accum, "\n\t", 0))
	end
end

strict_mode()
return strict_mode
