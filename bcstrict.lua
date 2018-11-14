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

local function parse_uvs(s, x)
	local u, v = {}
	v, x = unpack("i", s, x)
	for j=1,v do
		v, x = unpack(">I2", s, x)
		u[v] = j-1
	end
	return u, x
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

local function parse_code(s, x, i)
	local d, v = {}
	v, x = unpack("i", s, x)

	for j=1,v do
		v, x = unpack(i, s, x)
		local o, b = v & 63, v>>23 & 511
		if o == 6 then -- GETTABUP
			d[#d+1] = {b, v>>14 & 511}
		elseif o == 8 then -- SETTABUP
			d[#d+1] = {v>>6 & 255, b}
		end
	end

	return d, x
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

local function check_function(a, s, x, ins_fmt, parent_source)
	local source, linedefined, lastlinedefined
	source, x = parse_string(s, x)
	source = source or parent_source
	linedefined, lastlinedefined, x = unpack("iixxx", s, x)

	local acs, kst, uvs
	acs, x = parse_code(s, x, ins_fmt)
	kst, x = parse_constants(s, x)
	uvs, x = parse_uvs(s, x)

	local nprotos
	nprotos, x = unpack("i", s, x)
	for j=1,nprotos do
		x = check_function(a, s, x, ins_fmt, source)
	end

	local dli, dlv, duv
	dli, dlv, duv, x = parse_debug(s, x)

	local env_upvalue = uvs[linedefined == 0 and 256 or 0]
	if env_upvalue then
		for j=1,#acs do
			if acs[j][1] == env_upvalue then
				a[#a+1] = source:match("@?(.*)")..":"..linedefined.."-"..lastlinedefined..": ".. kst[acs[j][2]-255]
			end
		end
	end

	return x
end

local function check_dump(s)
	local sig, ver, lit, isz, int, num, x = unpack("c4<I2=c6xxBxxjnx", s)
	assert(sig == "\x1bLua", "not a dump")
	assert(ver == 0x53, "not a standard 5.3 dump")
	assert(lit == "\x19\x93\r\n\x1a\n", "mangled dump (conversions?)")
	assert(int == 0x5678, "mangled dump (wrong-endian?)")
	assert(num == 370.5, "mangled dump (floats broken?)")
	local accum = {}
	assert(check_function(accum, s, x, "i"..isz, "") == #s+1)
	for j=1,#accum do
		print(accum[j])
	end
end

check_dump(string.dump(debug.getinfo(1, "f").func))
