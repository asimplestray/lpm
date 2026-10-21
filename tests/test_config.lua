-- tests/test_config.lua -- v1.1: override de espelho (config.apply_mirror).
--
-- O contrato do reencadeamento: a base do espelho é TROCAVEL, o path atrás
-- dela é propriedade do perfil e o perfil em si NUNCA é mutado (o cli usa
-- a cópia devolvida por apply_mirror).

local config = require("lpm.config")

local here = (arg and arg[0]) or "tests/test_config.lua"
local root = (here:match("^(.-)/?tests/test_config%.lua$") or ".")
if root == "" then root = "." end

local profile = dofile(root .. "/profiles/void.lua")

-- ============ 1. forma declarada do perfil ============
local arch = profile.donor
assert(arch.id == "arch" and arch.mirror, "arch declara a base do espelho")
assert(arch.mirror == "https://geo.mirror.pkgbuild.com", "base default do arch")
for _, r in ipairs(arch.repos) do
	assert(r.id and r.path and not r.url, "repo do arch usa path, não url absoluta")
	assert(r.path:sub(1, 1) == "/", "path absoluto (barra inicial)")
end
assert(arch.file_url_template:find("%%MIRROR%%", 1, false),
	"template do arch trama %MIRROR%")

local deb = profile.donors.debian
assert(deb.mirror == "https://deb.debian.org/debian", "base default do debian")
assert(deb.repos[1].path and not deb.repos[1].url, "repo do debian usa path")
assert(deb.file_url_template:find("%%MIRROR%%", 1, false),
	"template do debian trama %MIRROR%")

-- ============ 2. apply_mirror default (nil → usa a base do perfil) ============
local nd, err = config.apply_mirror(arch, nil)
assert(nd and not err, "default reencadeia")
assert(nd.mirror == arch.mirror, "base intacta")
assert(nd.repos[1].url == "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db",
	"url core reencadeada: " .. tostring(nd.repos[1].url))
assert(nd.repos[2].url == "https://geo.mirror.pkgbuild.com/extra/os/x86_64/extra.db",
	"url extra reencadeada")
-- o perfil NUNCA é mutado (o cli confia que dofile dá a forma limpa)
assert(arch.repos[1].url == nil, "perfil não recebe campo url")

-- ============ 3. override sem barra final (rackspace) ============
nd = config.apply_mirror(arch, "https://mirror.rackspace.com/archlinux")
assert(nd.mirror == "https://mirror.rackspace.com/archlinux", "base trocada")
assert(nd.repos[1].url ==
	"https://mirror.rackspace.com/archlinux/core/os/x86_64/core.db",
	"path do perfil preservado atrás da base nova")
assert(arch.repos[1].url == nil, "override não mutou o perfil")

-- ============ 4. barras finais da base são normalizadas ============
nd = config.apply_mirror(arch, "https://mirror.rackspace.com/archlinux///")
assert(nd.mirror == "https://mirror.rackspace.com/archlinux",
	"barras finais removidas (o path já traz a barra)")

-- ============ 5. base inválida ============
local bad, berr = config.apply_mirror(arch, "ftp://mirrors.kernel.org/archlinux")
assert(not bad and berr:find("http", 1, true), "esquema não-http é rejeitado")
bad = config.apply_mirror(arch, "   ")
assert(not bad and berr ~= nil, "base sem esquema é rejeitada")

-- ============ 6. forma legada (url absoluta) continua funcionando ============
local legacy = {
	id = "leg", mirror = "https://old.example",
	repos = { { id = "main", url = "https://old.example/main/dists.db" } },
}
nd = config.apply_mirror(legacy, nil)
assert(nd.repos[1].url == "https://old.example/main/dists.db", "legado intacto")
nd = config.apply_mirror(legacy, "https://new.example/pub")
assert(nd.repos[1].url == "https://new.example/pub/main/dists.db",
	"legado reencadeado pela base declarada")

local misdono = {
	id = "mis", mirror = "https://old.example",
	repos = { { id = "wrong", url = "https://elsewhere.example/d.db" } },
}
bad = config.apply_mirror(misdono, nil)
assert(not bad, "url legada que não casa com a base declarada é rejeitada")

-- ============ 7. debian: override de espelho alternativo ============
nd = config.apply_mirror(deb, "https://mirror.csclub.uwaterloo.ca/debian")
assert(nd.repos[1].url ==
	"https://mirror.csclub.uwaterloo.ca/debian/dists/stable/main/binary-amd64/Packages.gz",
	"url do índice debian reencadeada")

print("test_config: OK")
