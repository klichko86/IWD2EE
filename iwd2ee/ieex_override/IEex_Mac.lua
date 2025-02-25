
IEex_RegToOrdinal = {
	["eax"] = 0,
	["ecx"] = 1,
	["edx"] = 2,
	["ebx"] = 3,
	["esp"] = 4,
	["ebp"] = 5,
	["esi"] = 6,
	["edi"] = 7,
}

IEex_RegWordToOrdinal = {
	["ax"] = 0,
	["cx"] = 1,
	["dx"] = 2,
	["bx"] = 3,
}

function IEex_SignedHexStringToNumber(hexStr)
	local v = tonumber(hexStr, 16)
	if string.sub(hexStr, 1, 1) == "-" then
		return -(bit.bnot(v) + 1)
	end
	return v
end

function IEex_GetImmediateLength(immediate)

	local absoluteImmediate = bit.band(immediate, 0x80000000) ~= 0x0
		and bit.bnot(immediate) + 1
		or immediate + 1

	if absoluteImmediate <= 0x80 then
		return 1
	elseif absoluteImmediate <= 0x8000 then
		return 2
	elseif absoluteImmediate <= 0x80000000 then
		return 4
	else
		IEex_Error("Invalid")
	end
end

function IEex_EncodeGetImmediateLength(immediate)

	local absoluteImmediate = bit.band(immediate, 0x80000000) ~= 0x0
		and bit.bnot(immediate) + 1
		or immediate + 1

	if absoluteImmediate <= 0x80 then
		return 1
	elseif absoluteImmediate <= 0x80000000 then
		return 4
	else
		IEex_Error("Invalid RM")
	end
end

--[[

args = {
	["opcodeExtension"] - Mutually exclusive with reg, (they use the same bits in the encoding).
	["reg"] - String representing simple register. Direction, (reg<-rm vs rm<-reg), is determined by opcode. Examples:
		"eax", "ecx", etc.
	["rm"] - String representing RM encoded operand. Examples:
		"[42]"
		"[eax]"
		"[esi*1]"
		"[eax+42]"
		"[eax+esi*2]"
		"[esi*4+42]"
		"[eax+esi*8+42]"
}

func - Called for every byte generated by the encoding.

--]]
function IEex_EncodeRM(args, func)

	local opcodeExtension = args.opcodeExtension
	local opcodeImmediateLength = args.opcodeImmediateLength
	local argsReg = args.reg
	local argsRM = args.rm
	local argsOffsetAdjustment = args.offsetAdjustment
	local explicitRMIndirectLength

	local prefix
	-- RM Byte Start
	local rm
	local regOrExtension = 0
	local mod = 0
	-- RM Byte End
	local sibByte
	local offset
	local immediate = args.immediate

	-- Fill regOrExtension Start
	if opcodeExtension then
		regOrExtension = opcodeExtension
	end

	if argsReg then
		if opcodeExtension then
			IEex_Error("opcodeExtension and reg can't both be defined")
		end
		regOrExtension = IEex_RegToOrdinal[argsReg]
		if not regOrExtension then
			regOrExtension = IEex_RegWordToOrdinal[argsReg]
			if not regOrExtension then IEex_Error("Invalid reg") end
			prefix = 0x66
		end
	end
	-- Fill regOrExtension End

	local simpleReg = IEex_RegToOrdinal[argsRM]
	local simpleWordReg = IEex_RegWordToOrdinal[argsRM]

	if simpleReg or simpleWordReg then
		-- Direct reg, simple encoding
		if simpleWordReg then
			if argsReg and not prefix then IEex_Error("reg and rm must agree on operand size") end
			prefix = 0x66
		end
		rm = simpleReg or simpleWordReg
		mod = 3
	else

		local argsRMLen = #argsRM
		if argsRMLen >= 5 and argsRM:sub(1, 5) == "word:" then
			if argsReg and not prefix then IEex_Error("reg and rm must agree on operand size") end
			-- Word-size prefix
			prefix = 0x66
			explicitRMIndirectLength = 2
			argsRM = argsRM:sub(6, #argsRM)
		elseif argsRMLen >= 6 and argsRM:sub(1, 6) == "dword:" then
			explicitRMIndirectLength = 4
			argsRM = argsRM:sub(7, #argsRM)
		end

		-- Indirect addressing, complex encoding
		argsRMLen = #argsRM
		if argsRMLen < 3 or (argsRM:sub(1, 1) ~= "[" or argsRM:sub(argsRMLen) ~= "]") then
			IEex_Error("Invalid RM: \""..argsRM.."\"")
		end

		local plusMinusSplit, matchedPatterns = IEex_Split(argsRM:sub(2, argsRMLen - 1), "[%-+]", true, true)
		local splitLength = #plusMinusSplit

		if splitLength < 1 or splitLength > 3 then
			IEex_Error("Invalid RM")
		end

		local tryAsReg = function(section)
			local asReg = IEex_RegToOrdinal[section]
			if asReg then
				if rm then IEex_Error("Only one reg base allowed") end
				if sibByte then IEex_Error("Reg base must be defined before SIB") end
				rm = asReg
				return true
			end
			return false
		end

		local sibModOverride
		local doAsSIB = function(baseReg, sibReg, scaleOrdinal)

			if not sibReg then IEex_Error("Invalid RM") end
			if not scaleOrdinal then IEex_Error("Invalid RM") end
			if sibByte then IEex_Error("Only one SIB allowed") end

			if not baseReg then
				offset = 0
				sibModOverride = true
				baseReg = 5
			end

			sibByte = IEex_Flags({
				baseReg,
				bit.lshift(sibReg, 3),
				bit.lshift(scaleOrdinal, 6),
			})

			rm = 4
		end

		local tryAsSIB = function(section)

			local asteriskSplit = IEex_Split(section, "*", false, true)
			local asteriskSplitLen = #asteriskSplit

			if asteriskSplitLen == 1 then return false end
			if asteriskSplitLen ~= 2 then IEex_Error("Invalid RM") end

			local sibReg = IEex_RegToOrdinal[asteriskSplit[1]]
			if not sibReg then IEex_Error("Invalid RM") end
			if sibReg == 4 then IEex_Error("ESP cannot be scaled") end

			local scaleOrdinal = ({
				[1] = 0,
				[2] = 1,
				[4] = 2,
				[8] = 3,
			})[tonumber(asteriskSplit[2])]

			doAsSIB(rm, sibReg, scaleOrdinal)
			return true
		end

		local didAsOffset = false
		local doAsOffset = function(offsetIn, tryIndex)

			if not offsetIn then return false end
			if didAsOffset then IEex_Error("Only one offset allowed") end
			didAsOffset = true

			local signedOffset = (tryIndex == 1 or matchedPatterns[tryIndex - 1] == "+")
				and offsetIn or -offsetIn
			if argsOffsetAdjustment then signedOffset = signedOffset + argsOffsetAdjustment end
			if signedOffset == 0 then return true end
			offset = math.abs(signedOffset)

			if signedOffset >= 0 then
				if offset <= 0x7F then
					mod = 1
				elseif offset <= 0x7FFFFFFF then
					mod = 2
				else
					IEex_Error("Invalid RM")
				end
			else
				if offset <= 0x80 then
					offset = 0x100 - offset
					mod = 1
				elseif offset <= 0x80000000 then
					offset = 0x100000000 - offset
					mod = 2
				else
					IEex_Error("Invalid RM")
				end
			end

			return true
		end

		local tryAsOffset = function(section, tryIndex)
			return doAsOffset(tonumber(section, 16), tryIndex)
		end

		for i = 1, splitLength do
			local section = plusMinusSplit[i]
			if (not tryAsReg(section)) and (not tryAsSIB(section)) and (not tryAsOffset(section, i)) then
				IEex_Error("Invalid RM")
			end
		end

		-- Force offset adjustment even if no offset was defined
		if argsOffsetAdjustment and not didAsOffset then
			doAsOffset(0, 1)
		end

		-- SIB with no base reg is special case
		if sibModOverride then
			mod = 0
		end

		-- esp hijacks SIB for simple offsets
		if rm == 4 and not sibByte then
			doAsSIB(4, 4, 0)
		end

		-- [ebp] doesn't exist, upgrade to [ebp+byte]
		if rm == 5 and mod == 0 then
			offset = 0
			mod = 1
		end

		-- [offset] has special encoding
		if not rm then
			mod = 0
			rm = 5
		end
	end

	if prefix then
		func(prefix)
	end

	func(args.opcode)

	-- rmByte
	func(IEex_Flags({
		rm,
		bit.lshift(regOrExtension, 3),
		bit.lshift(mod, 6),
	}))

	if sibByte then
		func(sibByte)
	end

	if offset then
		IEex_ProcessNumberAsBytes(offset, mod == 1 and 1 or 4, func)
	end

	if immediate then
		local effectiveLength = (opcodeImmediateLength == 4 and explicitRMIndirectLength == 2) and 2 or opcodeImmediateLength
		IEex_ProcessNumberAsBytes(immediate, effectiveLength, func)
	end
end

function IEex_EncodeRMOpcode(args, encodingArgs)

	local firstArg = args[1]
	local secondArg = args[2]
	local firstOrdinal = IEex_RegToOrdinal[firstArg]
	local firstWordOrdinal = IEex_RegWordToOrdinal[firstArg]

	local opcode = encodingArgs.opcode
	if not opcode then IEex_Error("opcode must be defined") end

	local attemptAsImmediate = function(arg)
		local numAttempt = type(arg) == "number" and arg or tonumber(arg or "", 16)
		if numAttempt then

			local immediateOpcodes = encodingArgs.immediateOpcodes
			if not immediateOpcodes then IEex_Error("immediateOpcodes must be defined when using immediate") end

			local foundImmediateOpcodeDef = nil
			local immediateLength = IEex_EncodeGetImmediateLength(numAttempt)
			if immediateLength == 1 then
				foundImmediateOpcodeDef = immediateOpcodes["imm8"]
				if not foundImmediateOpcodeDef then
					foundImmediateOpcodeDef = immediateOpcodes["imm16/32"]
					encodingArgs.opcodeImmediateLength = 4
				else
					encodingArgs.opcodeImmediateLength = 1
				end
			elseif immediateLength == 4 then
				foundImmediateOpcodeDef = immediateOpcodes["imm16/32"]
				encodingArgs.opcodeImmediateLength = 4
			end

			if not foundImmediateOpcodeDef then
				IEex_Error("immediateOpcodes.imm8 or immediateOpcodes.imm16/32 must be defined when using the corresponding immediate length")
			end

			encodingArgs.opcode = foundImmediateOpcodeDef.opcode
			encodingArgs.opcodeExtension = foundImmediateOpcodeDef.extension
			encodingArgs.immediate = numAttempt
			return true
		end
		return false
	end

	if (not firstOrdinal) and (not firstWordOrdinal) then
		if not attemptAsImmediate(secondArg) then
			encodingArgs.reg = secondArg
		end
		encodingArgs.rm = firstArg
	else
		if not attemptAsImmediate(secondArg) then
			-- Set direction bit of opcode
			encodingArgs.opcode = (encodingArgs.noDirectionBit) and (opcode) or (opcode + 0x2)
			encodingArgs.reg = firstArg
			encodingArgs.rm = secondArg
		else
			encodingArgs.rm = firstArg
		end
	end

	local toReturn = {}
	IEex_EncodeRM(encodingArgs, function(byte)
		table.insert(toReturn, {byte, 1})
	end)

	return toReturn
end

function IEex_GetOffsetAdjustment(state)
	local adjust = state.unroll.nextEspAdjustment
	state.unroll.nextEspAdjustment = nil
	return adjust
end

IEex_GlobalAssemblyMacros = {

	["add_[ecx+edi]_al"] = "00 04 39",
	["add_[ecx+edi]_ax"] = "66 01 04 39",
	["add_[ecx+edi]_eax"] = "01 04 39",
	["add_eax_byte"] = "83 C0",
	["add_eax_dword"] = "05",
	["add_eax_edx"] = "03 C2",
	["add_eax_esi"] = "03 C6",
	["add_ebx_dword"] = "81 C3",
	["add_ebx_esi"] = "03 DE",
	["add_edi_byte"] = "83 C7",
	["add_edx_[esi+byte]"] = "03 56",
	["add_edx_eax"] = "03 D0",
	["add_edx_esi"] = "03 D6",
	["add_esi_dword"] = "81 C6",
	["add_esp_byte"] = "83 C4",
	["add_esp_dword"] = "81 C4",
	["add_esp_eax"] = "03 E0",
	["and_eax_byte"] = "83 E0",
	["and_eax_dword"] = "25",
	["call"] = "E8",
	["call_[dword]"] = "FF 15",
	["call_[eax+byte]"] = "FF 50",
	["call_[eax+dword]"] = "FF 90",
	["call_[ecx+dword]"] = "FF 91",
	["call_[edx+byte]"] = "FF 52",
	["call_[edx+dword]"] = "FF 92",
	["call_eax"] = "FF D0",
	["call_ebp"] = "FF D5",
	["call_esi"] = "FF D6",
	["cdq"] = "99",
	["cmove_eax_ebx"] = "0F 44 C3",
	["cmovne_eax_ebx"] = "0F 45 C3",
	["cmovne_eax_edi"] = "0F 45 C7",
	["cmovnz_ebx_eax"] = "0F 45 D8",
	["cmovnz_edi_ecx"] = "0F 45 F9",
	["cmp_[dword]_byte"] = "83 3D",
	["cmp_[eax+dword]_byte"] = "80 B8",
	["cmp_[eax]_byte"] = "83 38",
	["cmp_[ebp+byte]_byte"] = "83 7D",
	["cmp_[ebp+byte]_dword"] = "81 7D",
	["cmp_[ebp+byte]_ebx"] = "39 5D",
	["cmp_[ebp+dword]_byte"] = "83 BD",
	["cmp_[ebx+dword]_byte"] = "80 BB",
	["cmp_[ecx*4+dword]_eax"] = "39 04 8D",
	["cmp_[ecx+byte]_byte"] = "83 79",
	["cmp_[ecx+byte]_esi"] = "39 71",
	["cmp_[ecx+dword]_byte"] = "83 B9",
	["cmp_[esi*4+dword]_eax"] = "39 04 B5",
	["cmp_[esi+byte]_byte"] = "83 7E",
	["cmp_[esi+dword]_byte"] = "80 BE",
	["cmp_al_[dword]"] = "3A 05",
	["cmp_al_byte"] = "3C",
	["cmp_byte:[dword]_byte"] = "80 3D",
	["cmp_byte:[eax+byte]_byte"] = "80 78",
	["cmp_byte:[ebp+byte]"] = "80 7D",
	["cmp_byte:[edi+byte]_byte"] = "80 7F",
	["cmp_byte:[edi+dword]_byte"] = "80 BF",
	["cmp_byte:[edx+byte]_byte"] = "80 7A",
	["cmp_byte:[esi+dword]_byte"] = "80 BE",
	["cmp_byte:[esi]_byte"] = "80 3E",
	["cmp_eax_[dword]"] = "3B 05",
	["cmp_eax_[ebx+byte]"] = "3B 43",
	["cmp_eax_byte"] = "83 F8",
	["cmp_eax_dword"] = "3D",
	["cmp_eax_ebx"] = "3B C3",
	["cmp_eax_edx"] = "3B C2",
	["cmp_ebp_byte"] = "83 FD",
	["cmp_ebp_dword"] = "81 FD",
	["cmp_ebx_[ebp+byte]"] = "3B 5D",
	["cmp_ebx_eax"] = "3B D8",
	["cmp_ebx_edi"] = "3B DF",
	["cmp_ecx_[dword]"] = "3B 0D",
	["cmp_ecx_byte"]= "83 F9",
	["cmp_edi_[ebp+byte]"] = "3B 7D",
	["cmp_edi_dword"] = "81 FF",
	["cmp_edi_ebx"] = "39 DF",
	["cmp_edx_[esi+byte]"] = "3B 56",
	["cmp_edx_byte"] = "83 FA",
	["cmp_edx_ebx"] = "3B D3",
	["cmp_esi_dword"] = "81 FE",
	["cmp_esi_ebx"] = "3B F3",
	["cmp_esi_edi"] = "3B F7",
	["cmp_esi_edx"] = "3B F2",
	["dec_[ebp+byte]"] = "FF 4D",
	["dec_byte:[dword]"] = "FE 0D",
	["dec_eax"] = "48",
	["dec_edi"] = "4F",
	["fild_[esp+byte]"] = "DB 44 24",
	["fild_[esp+dword]"] = "DB 84 24",
	["fild_[esp]"] = "DB 04 24",
	["fstp_qword:[edi]"] = "DD 1F",
	["fstp_qword:[esp+byte]"] = "DD 5C 24",
	["fstp_qword:[esp+dword]"] = "DD 9C 24",
	["fstp_qword:[esp]"] = "DD 1C 24",
	["idiv_ecx"] = "F7 F9",
	["imul_eax_eax_byte"] = "6B C0",
	["imul_edx"] = "F7 EA",
	["imul_edx_[esi+byte]"] = "0F AF 56",
	["inc_[ebp+byte]"] = "FF 45",
	["inc_eax"] = "40",
	["inc_ebx"] = "43",
	["inc_ecx"] = "41",
	["inc_edi"] = "47",
	["inc_edx"] = "42",
	["inc_esi"] = "46",
	["ja_dword"] = "0F 87",
	["jae_dword"] = "0F 83",
	["jb_dword"] = "0F 82",
	["jbe_dword"] = "0F 86",
	["je_byte"] = "74",
	["je_dword"] = "0F 84",
	["jg_byte"] = "7F",
	["jg_dword"] = "0F 8F",
	["jl_byte"] = "7C",
	["jl_dword"] = "0F 8C",
	["jle_byte"] = "7E",
	["jle_dword"] = "0F 8E",
	["jmp_[dword]"] = "FF 25",
	["jmp_byte"] = "EB",
	["jmp_dword"] = "E9",
	["jne_byte"] = "75",
	["jne_dword"] = "0F 85",
	["jnz_dword"] = "0F 85",
	["jz_dword"] = "0F 84",
	["lea_eax_[ebp+byte]"] = "8D 45",
	["lea_eax_[ebp+dword]"] = "8D 85",
	["lea_eax_[ebp]"] = "8D 45 00",
	["lea_eax_[edi+byte]"] = "8D 47",
	["lea_eax_[esi+byte]"] = "8D 46",
	["lea_eax_[esi+dword]"] = "8D 86",
	["lea_eax_[esp+byte]"] = "8D 44 24",
	["lea_eax_[esp+dword]"] = "8D 84 24",
	["lea_ebx_[eax+byte]"] = "8D 58",
	["lea_ebx_[eax+dword]"] = "8D 98",
	["lea_ebx_[eax]"] = "8D 18",
	["lea_ebx_[edi+byte]"] = "8D 5F",
	["lea_ecx_[ebp+byte]"] = "8D 4D",
	["lea_ecx_[ebp+dword]"] = "8D 8D",
	["lea_ecx_[ebp]"] = "8D 4D 00",
	["lea_ecx_[ebx+byte]"] = "8D 4B",
	["lea_ecx_[ecx+dword]"] = "8D 89",
	["lea_ecx_[ecx+eax*4+dword]"] = "8D 8C 81",
	["lea_ecx_[esi+byte]"] = "8D 4E",
	["lea_ecx_[esi+dword]"] = "8D 8E",
	["lea_ecx_[esp+byte]"] = "8D 4C 24",
	["lea_edi_[eax+byte]"] = "8D 78",
	["lea_edi_[eax+dword]"] = "8D B8",
	["lea_edi_[eax]"] = "8D 78 00",
	["lea_edi_[esi+byte]"] = "8D 7E",
	["lea_esi_[ecx+dword]"] = "8D B1",
	["leave"] = "C9",
	["mov_[dword]_dword"] = "C7 05",
	["mov_[dword]_eax"] = "A3",
	["mov_[dword]_ecx"] = "89 0D",
	["mov_[dword]_edi"] = "89 3D",
	["mov_[dword]_esi"] = "89 35",
	["mov_[eax+dword]_edx"] = "89 90",
	["mov_[ebp+byte]_dword"] = "C7 45",
	["mov_[ebp+byte]_eax"] = "89 45",
	["mov_[ebp+byte]_ecx"] = "89 4D",
	["mov_[ebp+byte]_edi"] = "89 7D",
	["mov_[ebp+byte]_esp"] = "89 65",
	["mov_[ebp+dword]_dword"] = "C7 85",
	["mov_[ebp+dword]_eax"] = "89 85",
	["mov_[ebp+dword]_edi"] = "89 BD",
	["mov_[ebp+dword]_esp"] = "89 A5",
	["mov_[ebp]_dword"] = "C7 45 00",
	["mov_[ebp]_edi"] = "89 7D 00",
	["mov_[ebp]_esp"] = "89 65 00",
	["mov_[ebx]_dword"] = "C7 03",
	["mov_[ecx*4+dword]_eax"] = "89 04 8D",
	["mov_[ecx+byte]_dword"] = "C7 41",
	["mov_[ecx+dword]_dword"] = "C7 81",
	["mov_[ecx+dword]_eax"] = "89 81",
	["mov_[ecx+dword]_edx"] = "89 91",
	["mov_[ecx+eax*4]_edx"] = "89 14 81",
	["mov_[ecx+edi*4]_edx"] = "89 14 B9",
	["mov_[ecx]_dword"] = "C7 01",
	["mov_[edi+byte]_al"] = "88 47",
	["mov_[edi+byte]_byte"] = "C6 47",
	["mov_[edi+byte]_dword"] = "C7 47",
	["mov_[edi+byte]_eax"] = "89 47",
	["mov_[edi+byte]_esi"] = "89 77",
	["mov_[edi+dword]_al"] = "88 87",
	["mov_[edi+dword]_ax"] = "66 89 87",
	["mov_[edi+dword]_bx"] = "66 89 9F",
	["mov_[edi+dword]_byte"] = "C6 87",
	["mov_[edi+dword]_dword"] = "C7 87",
	["mov_[edi+dword]_eax"] = "89 87",
	["mov_[edi+dword]_edx"] = "89 97",
	["mov_[edi]_al"] = "88 07",
	["mov_[edi]_byte"] = "C6 07",
	["mov_[edi]_dword"] = "C7 47 00",
	["mov_[edi]_eax"] = "89 07",
	["mov_[edi]_esi"] = "89 37",
	["mov_[edx*4+dword]_eax"] = "89 04 95",
	["mov_[edx+byte]_eax"] = "89 42",
	["mov_[edx+byte]_ecx"] = "89 4A",
	["mov_[edx]_ecx"] = "89 0A",
	["mov_[esi+byte]_dword"] = "C7 46",
	["mov_[esi+byte]_eax"] = "89 46",
	["mov_[esi+byte]_ebx"] = "89 5E",
	["mov_[esi+byte]_edi"] = "89 7E",
	["mov_[esi+dword]_ax"] = "66 89 86",
	["mov_[esi+dword]_dword"] = "C7 86",
	["mov_[esi+dword]_eax"] = "89 86",
	["mov_[esi]_dword"] = "C7 06",
	["mov_[esp+byte]_dword"] = "C7 44 24",
	["mov_[esp+byte]_eax"] = "89 44 24",
	["mov_[esp+byte]_ebx"] = "89 5C 24",
	["mov_[esp+byte]_ecx"] = "89 4C 24",
	["mov_[esp+byte]_edi"] = "89 7C 24",
	["mov_al"] = "B0",
	["mov_al_[ecx+byte]"] = "8A 41",
	["mov_al_[edi+byte]"] = "8A 47",
	["mov_al_[esi+byte]"] = "8A 46",
	["mov_al_[esi+dword]"] = "8A 86",
	["mov_al_[esi]"] = "8A 46 00",
	["mov_al_[esp+byte]"] = "8A 44 24",
	["mov_al_byte:[dword]"] = "A0",
	["mov_al_byte:[edi]"] = "8A 07",
	["mov_ax_[ecx+byte]"] = "66 8B 41",
	["mov_bx"] = "66 BB",
	["mov_byte:[dword]_al"] = "A2",
	["mov_byte:[ebp+byte]_byte"] = "C6 45",
	["mov_byte:[edi]_al"] = "88 07",
	["mov_byte:[edi]_byte"] = "C6 07",
	["mov_byte:[esi+dword]_al"] = "88 86",
	["mov_byte:[esi+dword]_byte"] = "C6 86",
	["mov_cl_al"] = "8A C8",
	["mov_cl_byte:[edx+dword]"] = "8A 8A",
	["mov_cx_[ebx+byte]"] = "66 8B 4B",
	["mov_eax"] = "B8",
	["mov_eax_[dword]"] = "A1",
	["mov_eax_[eax+byte]"] = "8B 40",
	["mov_eax_[eax+dword]"] = "8B 80",
	["mov_eax_[eax]"] = "8B 00",
	["mov_eax_[ebp+byte]"] = "8B 45",
	["mov_eax_[ebp+dword]"] = "8B 85",
	["mov_eax_[ebp]"] = "8B 45 00",
	["mov_eax_[ebx+byte]"] = "8B 43",
	["mov_eax_[ecx+byte]"] = "8B 41",
	["mov_eax_[ecx+eax*4]"] = "8B 04 81",
	["mov_eax_[ecx]"] = "8B 01",
	["mov_eax_[edi+dword]"] = "8B 87",
	["mov_eax_[edi]"] = "8B 07",
	["mov_eax_[edx+byte]"] = "8B 42",
	["mov_eax_[edx+dword]"] = "8B 82",
	["mov_eax_[edx]"] = "8B 02",
	["mov_eax_[esi+byte]"] = "8B 46",
	["mov_eax_[esi+dword]"] = "8B 86",
	["mov_eax_[esi]"] = "8B 46 00",
	["mov_eax_[esp+byte]"] = "8B 44 24",
	["mov_eax_[esp]"] = "8B 04 24",
	["mov_eax_ebx"] = "8B C3",
	["mov_eax_ecx"] = "8B C1",
	["mov_eax_edi"] = "89 F8",
	["mov_eax_edx"] = "8B C2",
	["mov_eax_esi"] = "8B C6",
	["mov_eax_esp"] = "8B C4",
	["mov_eax_fs:[0]"] = "64 A1 00 00 00 00",
	["mov_ebp"] = "BD",
	["mov_ebp_esp"] = "8B EC",
	["mov_ebx"] = "BB",
	["mov_ebx_[dword]"] = "8B 1D",
	["mov_ebx_[eax+byte]"] = "8B 58",
	["mov_ebx_[ebp+byte]"] = "8B 5D",
	["mov_ebx_[ebx+dword]"] = "8B 9B",
	["mov_ebx_[esi+dword]"] = "8B 9E",
	["mov_ebx_eax"] = "8B D8",
	["mov_ebx_esp"] = "8B DC",
	["mov_ecx"] = "B9",
	["mov_ecx_[dword]"] = "8B 0D",
	["mov_ecx_[eax+byte]"] = "8B 48",
	["mov_ecx_[eax+dword]"] = "8B 88",
	["mov_ecx_[eax]"] = "8B 08",
	["mov_ecx_[ebp+byte]"] = "8B 4D",
	["mov_ecx_[ebx+dword]"] = "8B 8B",
	["mov_ecx_[ecx+dword]"] = "8B 89",
	["mov_ecx_[ecx]"] = "8B 09",
	["mov_ecx_[edi+dword]"] = "8B 8F",
	["mov_ecx_[edx+byte]"] = "8B 4A",
	["mov_ecx_[edx+dword]"] = "8B 8A",
	["mov_ecx_[edx]"] = "8B 4A 00",
	["mov_ecx_[esi+byte]"] = "8B 4E",
	["mov_ecx_[esi+dword]"] = "8B 8E",
	["mov_ecx_[esi]"] = "8B 0E",
	["mov_ecx_[esp+byte]"] = "8B 4C 24",
	["mov_ecx_[esp]"] = "8B 0C 24",
	["mov_ecx_eax"] = "8B C8",
	["mov_ecx_ebp"] = "89 E9",
	["mov_ecx_ebx"] = "8B CB",
	["mov_ecx_edi"] = "8B CF",
	["mov_ecx_edx"] = "89 D1",
	["mov_ecx_esi"] = "8B CE",
	["mov_ecx_esp"] = "8B CC",
	["mov_edi"] = "BF",
	["mov_edi_[eax+byte]"] = "8B 78",
	["mov_edi_[eax+dword]"] = "8B B8",
	["mov_edi_[ebp+byte]"] = "8B 7D",
	["mov_edi_[ebp+dword]"] = "8B BD",
	["mov_edi_[ebp]"] = "8B 7D 00",
	["mov_edi_[ebx]"] = "8B 3B",
	["mov_edi_[ecx+byte]"] = "8B 79",
	["mov_edi_[edi+byte]"] = "8B 7F",
	["mov_edi_[edi]"] = "8B 3F",
	["mov_edi_[esi+byte]"] = "8B 7E",
	["mov_edi_eax"] = "8B F8",
	["mov_edi_ebx"] = "8B FB",
	["mov_edi_ecx"] = "8B F9",
	["mov_edi_esp"] = "8B FC",
	["mov_edx"] = "BA",
	["mov_edx_[dword]"] = "8B 15",
	["mov_edx_[eax+byte]"] = "8B 50",
	["mov_edx_[eax+dword]"] = "8B 90",
	["mov_edx_[eax]"] = "8B 10",
	["mov_edx_[ebp+byte]"] = "8B 55",
	["mov_edx_[ebx+byte]"] = "8B 53",
	["mov_edx_[ebx+dword]"] = "8B 93",
	["mov_edx_[ebx]"] = "8B 53 00",
	["mov_edx_[ecx+byte]"] = "8B 51",
	["mov_edx_[ecx+edi*4]"] = "8B 14 B9",
	["mov_edx_[ecx]"] = "8B 11",
	["mov_edx_[edi+byte]"] = "8B 57",
	["mov_edx_[edi+dword]"] = "8B 97",
	["mov_edx_[edi]"] = "8B 57 00",
	["mov_edx_[edx+byte]"] = "8B 52",
	["mov_edx_[edx+dword]"] = "8B 92",
	["mov_edx_[edx]"] = "8B 52 00",
	["mov_edx_[esi+byte]"] = "8B 56",
	["mov_edx_[esi+dword]"] = "8B 96",
	["mov_edx_[esi]"] = "8B 16",
	["mov_edx_eax"] = "8B D0",
	["mov_edx_ecx"] = "89 CA",
	["mov_esi"] = "BE",
	["mov_esi_[eax+dword]"] = "8B B0",
	["mov_esi_[ebp+byte]"] = "8B 75",
	["mov_esi_[ebx+byte]"] = "8B 73",
	["mov_esi_[ebx+dword]"] = "8B B3",
	["mov_esi_[edi+byte]"] = "8B 77",
	["mov_esi_[esi+byte]"] = "8B 76",
	["mov_esi_[esi+dword]"] = "8B B6",
	["mov_esi_[esi]"] = "8B 36",
	["mov_esi_eax"] = "8B F0",
	["mov_esi_ecx"] = "8B F1",
	["mov_esp_[ebp+byte]"] = "8B 65",
	["mov_esp_[ebp+dword]"] = "8B A5",
	["mov_esp_[ebp]"] = "8B 65 00",
	["mov_fs:[0]_ecx"] = "64 89 0D 00 00 00 00",
	["mov_fs:[0]_esp"] = "64 89 25 00 00 00 00",
	["movsx_eax_al"] = "0F BE C0",
	["movsx_eax_word:[edi+byte]"] = "0F BF 47",
	["movsx_ecx_word:[edi+byte]"] = "0F BF 4F",
	["movzx_eax_ax"] = "0F B7 C0",
	["movzx_eax_byte:[eax+dword]"] = "0F B6 80",
	["movzx_eax_byte:[edi+byte]"] = "0F B6 47",
	["movzx_eax_word:[dword]"] = "0F B7 05",
	["movzx_eax_word:[edx+byte]"] = "0F B7 42",
	["movzx_eax_word:[esi+byte]"] = "0F B7 46",
	["movzx_eax_word:[esp+byte]"] = "0F B7 44 24",
	["movzx_ecx_word:[esi+byte]"] = "0F B7 4E",
	["movzx_esi_word:[ebp-byte]"] = "0F B7 75",
	["neg_eax"] = "F7 D8",
	["nop"] = "90",
	["or_eax_byte"] = "83 C8",
	["or_eax_ecx"] = "09 C8",
	["or_ebx_byte"] = "83 CB",
	["or_edx_eax"] = "0B D0",
	["pop_all_registers"] = "5F 5E 5A 59 5B 58",
	["pop_complete_state"] = "5F 5E 5A 59 5B 58 5D",
	["pop_eax"] = "58",
	["pop_ebp"] = "5D",
	["pop_ebx"] = "5B",
	["pop_ecx"] = "59",
	["pop_edi"] = "5F",
	["pop_edx"] = "5A",
	["pop_esi"] = "5E",
	["pop_registers"] = "5F 5E 5A 59 5B",
	["pop_state"] = "5F 5E 5A 59 5B 5D",
	["push_[dword]"] = "FF 35",
	["push_[eax]"] = "FF 30",
	["push_[ebp+byte]"] = "FF 75",
	["push_[ebp+dword]"] = "FF B5",
	["push_[ebp]"] = "FF 75 00",
	["push_[ebx+byte]"] = "FF 73",
	["push_[ebx+dword]"] = "FF B3",
	["push_[ecx+byte]"] = "FF 71",
	["push_[ecx]"] = "FF 31",
	["push_[edi+byte]"] = "FF 77",
	["push_[edi+dword]"] = "FF B7",
	["push_[edx+byte]"] = "FF 72",
	["push_[esi+byte]"] = "FF 76",
	["push_[esi+dword]"] = "FF B6",
	["push_[esp+byte]"] = "FF 74 24",
	["push_[esp]"] = "FF 34 24",
	["push_all_registers"] = "50 53 51 52 56 57",
	["push_byte"] = "6A",
	["push_complete_state"] = "55 8B EC 50 53 51 52 56 57",
	["push_dword"] = "68",
	["push_eax"] = "50",
	["push_ebp"] = "55",
	["push_ebx"] = "53",
	["push_ecx"] = "51",
	["push_edi"] = "57",
	["push_edx"] = "52",
	["push_esi"] = "56",
	["push_esp"] = "54",
	["push_registers"] = "53 51 52 56 57",
	["push_state"] = "55 8B EC 53 51 52 56 57",
	["push_word:[ebx+byte]"] = "66 FF 73",
	["restore_stack_frame"] = "5F 5E 5A 59 5B 8B E5 5D",
	["ret"] = "C3",
	["ret_word"] = "C2",
	["sar_eax"] = "C1 F8",
	["sar_edx"] = "C1 FA",
	["setz_al"] = "0F 94 C0",
	["shl_eax"] = "C1 E0",
	["shl_edx"] = "C1 E2",
	["shr_eax"] = "C1 E8",
	["sub_[ecx+edi]_al"] = "28 04 39",
	["sub_[ecx+edi]_ax"] = "66 29 04 39",
	["sub_[ecx+edi]_eax"] = "29 04 39",
	["sub_[esp]_eax"] = "29 04 24",
	["sub_eax_byte"] = "83 E8",
	["sub_eax_dword"] = "2D",
	["sub_eax_ebx"] = "2B C3",
	["sub_ecx_eax"] = "29 C1",
	["sub_ecx_edx"] = "29 D1",
	["sub_edi_dword"] = "81 EF",
	["sub_esp_byte"] = "83 EC",
	["sub_esp_dword"] = "81 EC",
	["sub_esp_eax"] = "2B E0",
	["sub_esp_edx"] = "2B E2",
	["test_[eax+byte]_dword"] = "F7 40",
	["test_[ebp+byte]_dword"] = "F7 45",
	["test_[ecx+byte]_byte"] = "F6 41",
	["test_[ecx+dword]_byte"] = "F6 81",
	["test_[ecx]_byte"] = "F6 41 00",
	["test_[edi+byte]_byte"] = "F6 47",
	["test_al_al"] = "84 C0",
	["test_eax_dword"] = "A9",
	["test_eax_eax"] = "85 C0",
	["test_ebx_dword"] = "F7 C3",
	["test_ebx_ebx"] = "85 DB",
	["test_ecx_ecx"] = "85 C9",
	["test_edi_edi"] = "85 FF",
	["test_edx_edx"] = "85 D2",
	["test_esi_esi"] = "85 F6",
	["test_si_si"] = "66 85 F6",
	["word"] = "66",
	["xor_eax_eax"] = "33 C0",
	["xor_ebx_ebx"] = "33 DB",
	["xor_ecx_ecx"] = "33 C9",
	["xor_edi_edi"] = "33 FF",
	["xor_edx_edx"] = "33 D2",
	["xor_esi_esi"] = "33 F6",

	["build_stack_frame"] = [[
		!push(ebp)
		!mov(ebp,esp)
	]],

	["destroy_stack_frame"] = [[
		!mov(esp,ebp)
		!pop(ebp)
	]],

	["push_all_registers_iwd2"] = [[
		!push(eax)
		!push(ebx)
		!push(ecx)
		!push(edx)
		!push(ebp)
		!push(esi)
		!push(edi)
	]],

	["pop_all_registers_iwd2"] = [[
		!pop(edi)
		!pop(esi)
		!pop(ebp)
		!pop(edx)
		!pop(ecx)
		!pop(ebx)
		!pop(eax)
	]],

	["push_registers_iwd2"] = [[
		!push(ebx)
		!push(ecx)
		!push(edx)
		!push(ebp)
		!push(esi)
		!push(edi)
	]],

	["pop_registers_iwd2"] = [[
		!pop(edi)
		!pop(esi)
		!pop(ebp)
		!pop(edx)
		!pop(ecx)
		!pop(ebx)
	]],

	["mark_esp"] = {
		["unroll"] = function(state, args)
			local arg = args[1]
			if arg then
				state.unroll.markedEspAdjustment = tonumber(arg, 16)
			else
				state.unroll.markedEspAdjustment = 0
			end
		end,
	},

	["adjust_marked_esp"] = {
		["unroll"] = function(state, args)
			local arg = args[1]
			if arg then
				state.unroll.markedEspAdjustment = state.unroll.markedEspAdjustment + IEex_SignedHexStringToNumber(arg)
			else
				IEex_Error("[!adjust_marked_esp] - Argument required!")
			end
		end,
	},

	["repeat"] = {
		["unroll"] = function(state, args)
			local resultTable = {}
			local insertIndex = 1
			local numArgs = #args
			for i = 1, args[1] do
				for j = 2, numArgs do
					resultTable[insertIndex] = args[j]
					insertIndex = insertIndex + 1
				end
			end
			return resultTable
		end,
	},

	["push"] = {
		["unroll"] = function(state, args)
			state.unroll.markedEspAdjustment = (state.unroll.markedEspAdjustment or 0) + 4
			local firstArg = args[1]
			local toPushOrdinal = IEex_RegToOrdinal[firstArg]
			if toPushOrdinal then return {{0x50 + toPushOrdinal, 1}} end
			local numAttempt = type(firstArg) == "number" and firstArg or tonumber(firstArg, 16)
			if numAttempt then
				if IEex_GetImmediateLength(numAttempt) == 1 then
					return {{0x6A, 1}, {numAttempt, 1}}
				else
					local toReturn = {{0x68, 1}}
					local i = 2
					IEex_ProcessNumberAsBytes(numAttempt, 4, function(byte)
						toReturn[i] = {byte, 1}
						i = i + 1
					end)
					return toReturn
				end
			else
				return IEex_EncodeRMOpcode(args, {
					["opcode"] = 0xFF,
					["opcodeExtension"] = 6,
					["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				})
			end
		end,
	},

	["mov"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x89,
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0xC7},
				},
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
			})
		end,
	},

	["pop"] = {
		["unroll"] = function(state, args)
			state.unroll.markedEspAdjustment = state.unroll.markedEspAdjustment - 4
			local toPushOrdinal = IEex_RegToOrdinal[args[1]]
			if toPushOrdinal then
				return {{0x58 + toPushOrdinal, 1}}
			else
				return IEex_EncodeRMOpcode(args, {
					["opcode"] = 0x8F,
				})
			end
		end,
	},

	["push_using_marked_esp"] = {
		["unroll"] = function(state, args)
			local oldAdjust = state.unroll.markedEspAdjustment
			state.unroll.markedEspAdjustment = oldAdjust + 4
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0xFF,
				["opcodeExtension"] = 6,
				["offsetAdjustment"] = oldAdjust,
			})
		end,
	},

	["lea"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x8D,
				["noDirectionBit"] = true,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
			})
		end,
	},

	["lea_using_marked_esp"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x8D,
				["noDirectionBit"] = true,
				["offsetAdjustment"] = state.unroll.markedEspAdjustment,
			})
		end,
	},

	["add"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x3,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0x81, ["extension"] = 0},
					["imm8"] = {["opcode"] = 0x83, ["extension"] = 0},
				},
				["noDirectionBit"] = true,
			})
		end,
	},

	["and"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x23,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0x81, ["extension"] = 4},
					["imm8"] = {["opcode"] = 0x83, ["extension"] = 4},
				},
				["noDirectionBit"] = true,
			})
		end,
	},

	["sub"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x2B,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0x81, ["extension"] = 5},
					["imm8"] = {["opcode"] = 0x83, ["extension"] = 5},
				},
				["noDirectionBit"] = true,
			})
		end,
	},

	["xor"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x33,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0x81, ["extension"] = 6},
					["imm8"] = {["opcode"] = 0x83, ["extension"] = 6},
				},
				["noDirectionBit"] = true,
			})
		end,
	},

	["cmp"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x39,
				["offsetAdjustment"] = IEex_GetOffsetAdjustment(state),
				["immediateOpcodes"] = {
					["imm16/32"] = {["opcode"] = 0x81, ["extension"] = 7},
					["imm8"] = {["opcode"] = 0x83, ["extension"] = 7},
				},
			})
		end,
	},

	["test"] = {
		["unroll"] = function(state, args)
			return IEex_EncodeRMOpcode(args, {
				["opcode"] = 0x85,
				["noDirectionBit"] = true,
			})
		end,
	},

	["marked_esp"] = {
		["unroll"] = function(state, args)
			state.unroll.nextEspAdjustment = state.unroll.markedEspAdjustment
		end,
	},

	["ret"] = {
		["unroll"] = function(state, args)
			local firstArg = args[1]
			local amount = firstArg and (type(firstArg) == "number" and firstArg or tonumber(firstArg, 16)) or 0
			if amount == 0 then return {{0xC3, 1}} end
			if IEex_GetImmediateLength(amount) <= 2 then
				local toReturn = {{0xC2, 1}}
				local i = 2
				IEex_ProcessNumberAsBytes(amount, 2, function(byte)
					toReturn[i] = {byte, 1}
					i = i + 1
				end)
				return toReturn
			else
				IEex_Error("!ret() cannot return > 0xFFFF")
			end
		end,
	},

	["IF"] = {
		["unroll"] = function(state, args)
			if not args[1] then
				state.unroll.forceIgnore = true
			end
		end,
	},
	["ENDIF"] = {
		["unroll"] = function(state, args)
			state.unroll.forceIgnore = false
		end
	},
}
