-- lpm/version.lua
--
-- Comparação de versões, portada linha a linha dos algoritmos oficiais das
-- duas famílias de repositório que o lpm usa como doador:
--
--   * pacman/alpm (Arch):   rpmvercmp() + parseEVR() de lib/libalpm/version.c.
--                           Inclui o patch de 2011 "versions must be same
--                           length to be equal" (em empate de conteúdo, a
--                           versão com string mais CURTA vence). Não inclui o
--                           "separator-length check" herdado do rpm 4.8.1,
--                           porque sua presença contraria a suíte de testes
--                           oficial do pacman (os casos "1a 1.a 1" e
--                           "23.3.a 23.3a -1" só batem sem esse check).
--   * dpkg (Debian/Ubuntu): order() + verrevcmp() de lib/dpkg/version.c
--                           (semântica exata de deb-version(5), incluindo o
--                           '~' que ordena ANTES do fim da versão).
--   * xbps (Void, HOST):    mkcomponent()/vtest() de lib/external/dewey.c
--                           (dewey do pkgsrc/NetBSD adotado pelo xbps: dígitos
--                           por componente, modificadores alpha/beta/rc/pl,
--                           revisão pós '_' comparada por ÚLTIMO). 8 vetores
--                           oficiais de tests/libxbps/cmpver cobrém o port.
--
-- Todos os comparadores retornam -1 (a < b), 0 (iguais) ou 1 (a > b).

local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

----------------------------------------------------------------------
-- classes de byte (emulam ctype.h byte a byte)

local function isdigit_b(c) return c ~= nil and c >= 48 and c <= 57 end
local function isalpha_b(c)
	return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122))
end
local function isalnum_b(c) return isdigit_b(c) or isalpha_b(c) end

----------------------------------------------------------------------
-- pacman / alpm
----------------------------------------------------------------------

-- strcmp no espírito do C: cada segmento compara como se terminasse em '\0'
-- logo após o fim; '\0' ordena antes de qualquer byte.
local function cstrcmp(a, f1, l1, b, f2, l2)
	for i = 1, math.max(l1, l2) do
		local b1 = (i <= l1) and a:byte(f1 + i - 1) or 0
		local b2 = (i <= l2) and b:byte(f2 + i - 1) or 0
		if b1 ~= b2 then return b1 < b2 and -1 or 1 end
	end
	return 0
end

local function rpm_vercmp(a, b)
	if a == b then return 0 end

	local one, two = 1, 1
	local ptr1, ptr2 = 1, 1
	local one_len, two_len = #a, #b -- patch 2011: comprimento da string toda

	while true do
		while one <= #a and not isalnum_b(a:byte(one)) do one = one + 1 end
		while two <= #b and not isalnum_b(b:byte(two)) do two = two + 1 end
		if one > #a or two > #b then break end

		ptr1, ptr2 = one, two

		-- o tipo do segmento é decidido pelo primeiro byte de 'a'
		local isnum
		if isdigit_b(a:byte(ptr1)) then
			while ptr1 <= #a and isdigit_b(a:byte(ptr1)) do ptr1 = ptr1 + 1 end
			while ptr2 <= #b and isdigit_b(b:byte(ptr2)) do ptr2 = ptr2 + 1 end
			isnum = true
		else
			while ptr1 <= #a and isalpha_b(a:byte(ptr1)) do ptr1 = ptr1 + 1 end
			while ptr2 <= #b and isalpha_b(b:byte(ptr2)) do ptr2 = ptr2 + 1 end
			isnum = false
		end

		-- no C o comentário diz "não pode acontecer" e retorna -1 arbitrário
		if one == ptr1 then return -1 end
		-- tipos diferentes: numérico vence alfabético (vazio)
		if two == ptr2 then return isnum and 1 or -1 end

		if isnum then
			while one <= #a and a:byte(one) == 48 do one = one + 1 end
			while two <= #b and b:byte(two) == 48 do two = two + 1 end
			local l1 = math.max(0, ptr1 - one)
			local l2 = math.max(0, ptr2 - two)
			if l1 > l2 then return 1 end
			if l2 > l1 then return -1 end
		end

		local rc = cstrcmp(a, one, ptr1 - one, b, two, ptr2 - two)
		if rc ~= 0 then return rc end

		one, two = ptr1, ptr2 -- avança para o fim dos segmentos iguais
	end

	-- "final": ACABARAM as duas com conteúdo idêntico? patch 2011 -> a mais
	-- CURTA vence (caso "1.00"/"1.0", "23.3.a"/"23.3a")
	if one > #a and two > #b then
		local diff = two_len - one_len
		if diff > 0 then return 1 end
		if diff < 0 then return -1 end
		return 0
	end

	-- "final showdown": um sufixo alfabético restante nunca vence a string
	-- vazia: 1.0a < 1.0, 1.0rc1 < 1.0
	if (one > #a and not isalpha_b(b:byte(two))) or isalpha_b(a:byte(one)) then
		return -1
	end
	return 1
end

-- [epoch:]version[-release] -> epoch, version, release|nil
-- (port of parseEVR: a rodada de dígitos inicial + ':' define o epoch; o
--  release é tudo após o ÚLTIMO '-', na porção a partir do fim da rodada)
local function parse_evr(evr)
	if evr == nil or evr == "" then return "0", "", nil end

	local i = 1
	while i <= #evr and isdigit_b(evr:byte(i)) do i = i + 1 end
	-- i = posição do primeiro byte após a rodada inicial de dígitos

	local se -- índice do último '-' em [i .. #evr]
	for p = #evr, i, -1 do
		if evr:byte(p) == 45 then se = p; break end -- '-'
	end

	local epoch, ver, rel
	if evr:byte(i) == 58 then -- ':'
		local e = evr:sub(1, i - 1)
		epoch = (e == "") and "0" or e
		if se then
			ver = evr:sub(i + 1, se - 1)
			rel = evr:sub(se + 1)
		else
			ver = evr:sub(i + 1)
		end
	else
		epoch = "0" -- diferente do RPM: pacman sempre assume epoch 0
		if se then
			ver = evr:sub(1, se - 1)
			rel = evr:sub(se + 1)
		else
			ver = evr
		end
	end
	return epoch, ver, rel
end

--- port de alpm_pkg_vercmp
function M.pacman_cmp(a, b)
	if a == nil and b == nil then return 0 end
	if a == nil then return -1 end
	if b == nil then return 1 end
	if a == b then return 0 end

	local e1, v1, r1 = parse_evr(a)
	local e2, v2, r2 = parse_evr(b)

	local ret = rpm_vercmp(e1, e2)
	if ret == 0 then
		ret = rpm_vercmp(v1, v2)
		-- o pkgrel só é comparado quando AMBOS têm release
		if ret == 0 and r1 and r2 then
			ret = rpm_vercmp(r1, r2)
		end
	end
	return ret
end

----------------------------------------------------------------------
-- dpkg
----------------------------------------------------------------------

-- peso dos caracteres em verrevcmp (order() de lib/dpkg/version.c)
local function order_b(c)
	if c == nil then return 0 end
	if isdigit_b(c) then return 0 end
	if isalpha_b(c) then return c end
	if c == 126 then return -1 end -- '~'
	if c == 0 then return 0 end
	return c + 256
end

local function verrevcmp(a, b)
	local i, j = 1, 1
	local la, lb = #a, #b
	local function d(s, p) return p <= #s and isdigit_b(s:byte(p)) end

	while i <= la or j <= lb do
		local first_diff = 0

		-- região não-numérica: compara peso a peso
		while (i <= la and not d(a, i)) or (j <= lb and not d(b, j)) do
			local ac = order_b(a:byte(i))
			local bc = order_b(b:byte(j))
			if ac ~= bc then return ac - bc end
			i = i + 1
			j = j + 1
		end

		while d(a, i) and a:byte(i) == 48 do i = i + 1 end
		while d(b, j) and b:byte(j) == 48 do j = j + 1 end

		while d(a, i) and d(b, j) do
			if first_diff == 0 then first_diff = a:byte(i) - b:byte(j) end
			i = i + 1
			j = j + 1
		end

		if d(a, i) then return 1 end
		if d(b, j) then return -1 end
		if first_diff ~= 0 then return first_diff end
	end
	return 0
end

-- parse de versão Debian (port do parseversion() de parsehelp.c, tolerante)
-- retorna tabela { epoch, version, revision } ou nil+msg em erro duro.
function M.dpkg_parse(vstr)
	if type(vstr) ~= "string" or vstr == "" then
		return nil, "versão vazia"
	end
	local s = trim(vstr)
	if s:match("%s") then
		return nil, "versão com espaço embutido: " .. vstr
	end

	local ep = 0
	local colon = s:find(":")
	if colon then
		local digits = s:sub(1, colon - 1)
		if digits == "" then
			return nil, "epoch vazio em " .. vstr
		elseif digits:match("^%d+$") then
			ep = tonumber(digits)
			s = s:sub(colon + 1)
			if s == "" then
				return nil, "nada depois do ':' em " .. vstr
			end
		else
			return nil, "epoch não numérico em " .. vstr
		end
	end

	local ver, rev = s:match("^(.+)%-(.+)$") -- split no ÚLTIMO '-'
	if not ver then ver, rev = s, "" end
	if ver == "" then
		return nil, "número de versão vazio em " .. vstr
	end

	return { epoch = ep, version = ver, revision = rev }
end

function M.dpkg_cmp(a, b)
	if a == b then return 0 end
	if a == nil then return -1 end
	if b == nil then return 1 end
	local pa, ea = M.dpkg_parse(a)
	local pb, eb = M.dpkg_parse(b)
	if not pa then error("dpkg: " .. tostring(ea)) end
	if not pb then error("dpkg: " .. tostring(eb)) end

	if pa.epoch > pb.epoch then return 1 end
	if pa.epoch < pb.epoch then return -1 end

	local rc = verrevcmp(pa.version, pb.version)
	if rc ~= 0 then
		return rc < 0 and -1 or 1
	end
	rc = verrevcmp(pa.revision, pb.revision)
	return rc < 0 and -1 or (rc > 0 and 1 or 0)
end

----------------------------------------------------------------------
-- xbps (dewey — lib/external/dewey.c, importado do pkgsrc)
----------------------------------------------------------------------

-- valores CONGELADOS do enum em dewey.c ("do not modify these values")
local Alpha, Beta, RC, Dot, Patch = -3, -2, -1, 0, 1

-- modifiers[] do dewey.c: prefixo case-insensitive → valor emitido
local x_mods = {
	{ "alpha", Alpha }, { "beta", Beta }, { "pre", RC },
	{ "rc", RC }, { "pl", Dot }, { ".", Dot },
}

-- mkcomponent: consome o prefixo de `s` a partir de i e emite componentes.
-- retorna (i próximo, {v = componentes emitidas}, revisão capturada|nil)
local function mkcomponent(s, i)
	local function fail() error("dewey: componente inválida na pos " .. i) end
	local c = s:byte(i)
	if c == nil then fail() end

	-- ramos na ORDEM do C: dígito, modificadores, '_', letra, outro
	if isdigit_b(c) then
		local n = 0
		local st = i
		while i <= #s and isdigit_b(s:byte(i)) do
			n = n * 10 + (s:byte(i) - 48)
			i = i + 1
		end
		return i, { { n } }, nil
	end

	-- strncasecmp: case-insensitive
	for _, m in ipairs(x_mods) do
		local pre = s:sub(i, i + #m[1] - 1):lower()
		if pre == m[1] then
			return i + #m[1], { { m[2] } }, nil
		end
	end

	if c == 95 then -- '_': revisão do xbps (comparada por ÚLTIMO)
		local st = i
		i = i + 1
		local n = 0
		while i <= #s and isdigit_b(s:byte(i)) do
			n = n * 10 + (s:byte(i) - 48)
			i = i + 1
		end
		-- no C o loop roda 0 vezes quando não há dígito: n fica 0
		return i, {}, n
	end

	if isalpha_b(c) then
		local low = string.char(c):lower():byte()
		-- strchr(alphas, tolower(c)) -> posição 1-based; índice+1
		return i + 1, { { Dot, (low - 97) + 1 } }, nil
	end

	-- separador qualquer ('-', '+', etc.): avança sem emitir nada
	return i + 1, {}, nil
end

-- mkversion: "2.15_3" -> { {1,0,-?}, revision=3 } no espírito do arr_t
local function mkversion(ver)
	local ap = { c = 0, v = {}, revision = 0 }
	local i = 1
	while i <= #ver do
		local ni, out, rev = mkcomponent(ver, i)
		i = ni
		for _, vv in ipairs(out) do
			for _, w in ipairs(vv) do
				ap.c = ap.c + 1
				table.insert(ap.v, w)
			end
		end
		if rev then ap.revision = rev end
	end
	return ap
end

-- DIGIT(v, c, n): além da contagem vale 0
local function xdigit(ap, i)
	if i <= ap.c then return ap.v[i] end
	return 0
end

-- result(cmp, tst): vtest usa só LT e GT via xbps_cmpver
local function vtest_cmp(lhs, rhs)
	local c = math.max(lhs.c, rhs.c)
	for i = 1, c do
		local cmp = xdigit(lhs, i) - xdigit(rhs, i)
		if cmp ~= 0 then
			return cmp < 0 and -1 or 1
		end
	end
	local rc = lhs.revision - rhs.revision
	return rc < 0 and -1 or (rc > 0 and 1 or 0)
end

--- port de xbps_cmpver (dewey_cmp + LT/GT)
function M.xbps_cmp(a, b)
	if a == b then return 0 end
	if a == nil then return -1 end
	if b == nil then return 1 end
	local lhs, rhs = mkversion(a), mkversion(b)
	local rc = vtest_cmp(lhs, rhs)
	return rc
end

----------------------------------------------------------------------
-- utilitários dependentes de estilo de versão
----------------------------------------------------------------------

local style_cmp = {
	pacman = M.pacman_cmp,
	deb = M.dpkg_cmp,
	xbps = M.xbps_cmp,
}

--- compara versões dizendo em que "língua" estão
function M.cmp(style, a, b)
	local f = style_cmp[style]
	if not f then error("estilo de versão desconhecido: " .. tostring(style)) end
	return f(a, b)
end

--- "nome>=ver" / "nome<ver" / "nome=ver" / "nome" (estilo pacman; o nome pode
--- conter '-' e o restante só vira restrição se começar com <, > ou =)
-- retorna { name = , op = |nil, ver = |nil }
function M.parse_dep(s)
	s = trim(s)
	local name, rest = s:match("^([^<>=]+)(.*)$")
	if not name then return nil end
	name, rest = trim(name), trim(rest)
	-- nota: Lua patterns NÃO têm alternância '|'; op é manualmente 1ou2 chars
	local op, ver
	local c1 = rest:sub(1, 1)
	if c1 == "<" or c1 == ">" or c1 == "=" then
		if rest:sub(2, 2) == "=" then
			op, ver = c1 .. "=", trim(rest:sub(3))
		else
			op, ver = c1, trim(rest:sub(2))
		end
		if ver == "" then ver = nil end
	end
	return { name = name, op = op, ver = ver }
end

--- satisfaz? comp(ver_instalado, op, ver) na língua do estilo
function M.satisfies(style, installed_ver, op, ver, aux_cmp)
	if not op or not ver then return true end
	local c = M.cmp(style, installed_ver, ver, aux_cmp)
	if op == ">=" then return c >= 0 end
	if op == "<=" then return c <= 0 end
	if op == ">" then return c > 0 end
	if op == "<" then return c < 0 end
	if op == "=" or op == "==" then return c == 0 end
	error("operador de restrição desconhecido: " .. tostring(op))
end

return M
