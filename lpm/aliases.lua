-- lpm/aliases.lua
--
-- OVERRIDES de exceção para o ALIASING AUTOMÁTICO (v1.2.1 — pedido do
-- usuário: a tabela manual de antes era ineficiente). Quem resolve a
-- maioria das deps hoje NÃO é esta tabela, são os DADOS:
--   * camada A (preflight.deboname_satisfied): nome estilo Debian
--     'libssl3'/'libc6' reconstrói o soname ('libssl.so.3'/'libc.so.6');
--     se o host provê ESSA ABI, a dep está satisfeita e o nome traduz
--     por si mesmo (Void-current até adotou nomes lib<N> nativamente);
--   * camada B (preflight.provider_sonames_on_host): dep virtual cujo
--     provedor declara sonames que TODOS existem no host = mesmo
--     componente (provado no caso real 'libgl'→libglvnd do doador).
-- Fica aqui SÓ o que o automático não consegue provar: nome sem
-- reconstrução soname ('zlib1g') ou ABI que o mapa do host não tem.
-- Regra: entra POR BUG REAL com o porquê documentado, nunca por caso antecipado.
--
-- formato: canonical = { pacman = "...", deb = "...", xbps = "..." }
-- (chaves ausentes caem no nome canônico)

return {
	zlib = { pacman = "zlib", deb = "zlib1g", xbps = "zlib" }, -- sem prefixo lib
	libffi = { xbps = "libffi", deb = "libffi8" },             -- host não provê .so.8? todo: auditar
	libuv = { deb = "libuv1" },
	audit = { deb = "libaudit1", xbps = "audit-libs" },
}
