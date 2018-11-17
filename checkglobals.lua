#!/usr/bin/env lua53
local bcstrict = require "bcstrict"
bcstrict()
for j=1,#arg do
	bcstrict( nil, assert(loadfile(arg[j])))
end
