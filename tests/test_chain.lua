-- tests/test_chain.lua -- planejador de cadeia (v0.3): resolução de deps
-- no índice do doador (por nome, provides e sonames), dedupe de nós
-- repetidos, ordem pós-ordem (provedor antes de dependente) e as regras
-- do projeto (nativo velho = bloqueador; soname no host satisfaz).
--
-- Fixtures: índices/hospedados FAKE — nada de rede nem arquivo de repo.

local here = (arg and arg[0]) or "tests/test_chain.lua"
local root = here:match("^(.-)/?tests/") or "."
package.path = root .. "/?.lua;" .. package.path

local chain = require("lpm.chain")

-- ============ índice fake do doador (estilo Arch) ============
local E = {
	gcc15 = {
		name = "gcc15", version = "15.3.0-2", repo = "extra",
		depends = {
			{ name = "gcc15-libs" },
			{ name = "binutils", op = ">=", ver = "2.28" },
			{ name = "zstd" },
			{ name = "libisl.so", op = "=", ver = "23-64" },
		},
	},
	["gcc15-libs"] = {
		name = "gcc15-libs", version = "15.3.0-2", repo = "extra",
		depends = { { name = "glibc", op = ">=", ver = "2.27" } },
	},
	libisl = {
		-- o Arch nomeia os provedores de soname com prefixo lib e declara
		-- provides: nome virtual + soname (caso real do índice: libisl 0.28)
		name = "libisl", version = "0.28-1", repo = "core",
		provides = { { name = "isl" }, { name = "libisl.so", op = "=", ver = "23-64" } },
		depends = { { name = "gmp" } },
	},
	gmp = { name = "gmp", version = "6.3.0-2", repo = "core", depends = {} },
	foo = { name = "foo", version = "1.0-1", repo = "extra", depends = {} },
}
local by_name = { gcc15 = E.gcc15, ["gcc15-libs"] = E["gcc15-libs"],
	libisl = E.libisl, gmp = E.gmp, foo = E.foo }
local by_provides = { isl = E.libisl, ["libisl.so"] = E.libisl }

local function search(name, via_provides)
	return (via_provides and by_provides[name]) or by_name[name]
end

-- ============ host fake ============
-- Void com: binutils 2.47, zstd 1.5, glibc 2.41, gmp — e NADA de isl.
local installed = {
	binutils = "2.47_4", zstd = "1.5.7_1", glibc = "2.41_1", gmp = "6.3.0_3",
	cpio = "2.15_1",
}
-- soname map do pkgdb: libc.so.6 provido; libisl.so.23 NÃO.
local shlibs = { ["libc.so.6"] = "glibc", ["libz.so.1"] = "zlib" }

local ctx = {
	search = search, installed = installed, shlibs = shlibs,
	host_provides = { sh = "bash" },
	donor_style = "pacman", host_style = "xbps",
}

-- ============ 1. cadeia: gcc15 → gcc15-libs + libisl (soname) → gmp ============
local p = chain.plan({ E.gcc15 }, ctx)
assert(p.ok, "plano ok: " .. tostring(p.issues[1]))
-- ordem PÓS-ORDEM: provedores primeiro; gcc15 (o pedido) é o ÚLTIMO
local nomes = {}
for _, e in ipairs(p.ordered) do nomes[#nomes + 1] = e.name end
assert(nomes[#nomes] == "gcc15", "o pedido entra por último: " .. nomes[#nomes])
assert(table.concat(nomes, ","):find("libisl", 1, true), "libisl no plano")
-- gmp (dep do libisl) JÁ está no host → satisfeito, fora do plano
assert(not table.concat(nomes, ","):find("gmp", 1, true), "gmp no host: fora do plano")
-- quem estava no host não entra: binutils/zstd/glibc/gmp
assert(not table.concat(nomes, ","):find("binutils", 1, true), "binutils no host: fora do plano")
assert(not table.concat(nomes, ","):find("zstd", 1, true), "zstd no host: fora do plano")
assert(#p.ordered == 3, "3 nós (gcc15, gcc15-libs, libisl): " .. #p.ordered)
-- 'why' diz por que cada nó entrou
assert(p.why.gcc15 == "requested on the CLI")
assert((p.why.libisl or ""):find("libisl", 1, true), "why de libisl cita o soname")

-- ============ 2. soname provido pelo host: nada a converter ============
-- depende só de libc.so.6 (host tem) → plano de 1 nó
local p2 = chain.plan({ { name = "foo", depends = { { name = "libc.so", op = "=", ver = "6-64" } } } },
	ctx)
assert(p2.ok, "soname do host satisfeito")
assert(#p2.ordered == 1, "só o próprio foo entra")

-- ============ 3. nome já no host MAS versão insuficiente: BLOQUEADOR ============
local E_velho = { name = "velho", version = "1.0-1", repo = "extra",
	depends = { { name = "binutils", op = ">=", ver = "2.99" } } }
local p3 = chain.plan({ E_velho }, ctx)
assert(not p3.ok, "nativo velho é bloqueador")
assert((p3.issues[1] or ""):find("decis", 1, true), "mensagem cita decisão do usuário")
-- e NEM enfileira conversão do doador (não existe pois binutils está no host)

-- ============ 4. dep sem provedor em lugar nenhum ============
local p4 = chain.plan({ { name = "zig", version = "1-1", repo = "extra",
	depends = { { name = "pacote-inexistente" } } } }, ctx)
assert(not p4.ok, "dep sem provedor bloqueia")
assert((p4.issues[1] or ""):find("pacote-inexistente", 1, true))

-- ============ 5. dep de nome resolvida por PROVIDES (nome virtual) ============
-- 'isl' não existe como pacote ('libisl' carrega o provides 'isl')
local p5 = chain.plan({ { name = "isluser", version = "1-1", repo = "extra",
	depends = { { name = "isl" } } } }, ctx)
assert(p5.ok, "provides resolve nome virtual: " .. tostring(p5.issues[1]))
assert(p5.ordered[1].name == "libisl" or #p5.ordered == 2, "libisl entra pelo provides")

-- ============ 6. virtual provido pelo HOST (antes do doador) ============
-- xz pede 'sh': no Void é provides do DASH/bash locais — não puxar bash do
-- doador (ele nem caberia: glibc 2.44 > 2.41).
local p7 = chain.plan({
	{ name = "xz-fake", version = "5.8.4-1", repo = "core",
		depends = { { name = "sh" } } },
}, ctx)
assert(p7.ok, "sh do host satisfaz sem doador: " .. tostring(p7.issues[1]))
assert(#p7.ordered == 1, "só o próprio nó entra: " .. #p7.ordered)

-- ============ 7. nó repetido: dedupe por nome (diamante) ============-- dois pedidos no CLI que dividem a mesma dep (gcc15-libs)
local p6 = chain.plan({ E.gcc15, E["gcc15-libs"] }, ctx)
local vistos = {}
for _, e in ipairs(p6.ordered) do
	assert(not vistos[e.name], "duplicado no plano: " .. e.name)
	vistos[e.name] = true
end
assert(p6.why["gcc15-libs"] ~= nil)

-- ============ 8. candidatos derivados do soname (v2.0.5) ============
-- O nome derivado é só um palpite de BUSCA no índice; quem confirma o
-- provedor é o DT_SONAME do payload baixado (probe no cli). Nunca o nome.
local c = chain.provider_candidates("libhspell.so.0")
assert(c[1] == "libhspell" and c[2] == "hspell", "stem + forma sem 'lib'")
assert(c[3] == "libhspell0" and c[5] == "hspell0",
	"convenção Debian da major no nome (libhspell0)")
local seen = {}
for _, n in ipairs(c) do
	assert(not seen[n], "candidato duplicado: " .. n)
	seen[n] = true
end

c = chain.provider_candidates("libgtk-3.so.0")
assert(c[1] == "libgtk-3" and c[2] == "gtk-3" and c[3] == "gtk3",
	"variação com e sem hífen (nome real de pacote: gtk3)")
assert(c[5] == "libgtk-3-0", "convenção Debian com hífen (libgtk-3-0)")

c = chain.provider_candidates("libfoo.so.1.2.3")
assert(c[1] == "libfoo" and c[2] == "foo", "versão composta do soname")
assert(c[3] == "libfoo1" and c[4] == "libfoo-1", "major 1 do soname composto")

assert(#chain.provider_candidates("libfoo") == 0, "sem '.so' não inventa nome")
local curto = chain.provider_candidates("liba.so.1")
assert(curto[1] == "liba", "stem continua candidato")
for _, n in ipairs(curto) do
	assert(#n >= 2, "candidato curto demais: " .. n)
end
assert(#chain.provider_candidates(nil) == 0, "entrada inválida não explode")

print("test_chain: OK")
