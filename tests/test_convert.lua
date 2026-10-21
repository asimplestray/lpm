-- tests/test_convert.lua -- a tradução de língua doador → xbps, com os
-- empíricos do xbps 0.60 gravados como casos: versão válida (alnum, '.',
-- '~', ':' e UM '_'rev final) e dep exata em formato pkgver completo
-- ('nome=ver' NÃO casa no solver — 'perl-base-5.40.1...' casou).

local convert = require("lpm.convert")

local function eq(got, want, label)
	if got ~= want then
		error(("falhou: %s → obtive %s, esperava %s"):format(label,
			tostring(got), tostring(want)), 2)
	end
end

local tx = { pkgver = { ["perl-base"] = "5.40.1.6.deb13u1_1" },
	vpkg = { ["perlapi-5.40.0"] = "perl-base" } }

-- versão → língua xbps (Debian e Arch)
eq(convert.version_to_xbps("5.40.1-6+deb13u1"), "5.40.1.6.deb13u1_1",
	"Debian '5.40.1-6+deb13u1' (não pode ter '-' nem '+')")
eq(convert.version_to_xbps("3.03+dfsg2-8"), "3.03.dfsg2.8_1",
	"Debian '3.03+dfsg2-8'")
eq(convert.version_to_xbps("1.0"), "1.0_1", "sem revisão recebe _1")
eq(convert.version_to_xbps("16.2.1+r1"), "16.2.1.r1_1", "Arch com '+'")

-- rewrite de dep: membro da transação → pkgver exato (sem '='!)
eq(convert.rewrite_dep("perl-base>=5.40.0.6_1", tx, "libtext"),
	"perl-base-5.40.1.6.deb13u1_1", "dep de pkg convertido → pkgver")
eq(convert.rewrite_dep("perlapi-5.40.0>=0", tx, "libtext"),
	"perl-base-5.40.1.6.deb13u1_1", "dep por vpkg da transação → provider")
-- dep de pacote que já existe no host: NADA muda (o solver casa instalado)
eq(convert.rewrite_dep("perl>=0", tx, "libtext"), "perl>=0",
	"dep de instalado fica como está")
-- dep do próprio pacote (auto-dep): intocada
eq(convert.rewrite_dep("libtext-charwidth-perl>=0", tx, "libtext"),
	"libtext-charwidth-perl>=0", "self-dep intocada")
-- soname nunca é reescrito
eq(convert.rewrite_dep("libc.so.6>=2.4_1", tx, "libtext"),
	"libc.so.6>=2.4_1", "soname cru passa")
-- sem transação: passa cru
eq(convert.rewrite_dep("glibc>=2.4_1", nil, "x"), "glibc>=2.4_1",
	"tx nil → dep intacta")
