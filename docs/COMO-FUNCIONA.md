# Como funciona

## 1. Mapa da super stock
O script le a geometria e os metadados LP direto do arquivo (raw ou sparse, sem converter):
tamanho do dispositivo, **alinhamento**, primeiro setor, slots, tamanho da metadata, grupos
(com o maximo de cada um), ordem, atributos e tamanho de cada particao.
Nada disso e digitado a mao: o `lpmake` e chamado com os valores da propria super stock.

## 2. Por que o alinhamento importa
Uma super Samsung tipica usa alinhamento de 1 MiB (primeiro setor 2048 e cada particao comecando
em multiplo de 2048 setores). Montar com outro alinhamento (por exemplo `--alignment 4096`) gera
primeiro setor 536 e particoes desalinhadas: a estrutura deixa de ser a do original. O script
reproduz o alinhamento lido do original e confere isso no final.

## 3. Extracao e remontagem
1. super stock sparse -> raw (`simg2img`) -> `lpunpack` das particoes que ficam;
2. GSI (raw/sparse/.xz/.gz) -> raw; se o tamanho nao for multiplo de 4096, e completada com zeros
   numa copia (o arquivo original nunca e alterado);
3. `lpmake --sparse` com as particoes na mesma ordem, grupo e atributos da stock.

## 4. Regra de posicao
Em cada particao: `inicio = arredondar_para_cima(fim_da_anterior, alinhamento_em_setores)`.
O script recalcula as posicoes previstas e compara com as reais.

## 5. Veredito
| Deve ser IGUAL ao original | Deve MUDAR como previsto |
|---|---|
| versao/tamanho/slots da metadata, flags, primeiro setor, tamanho da super, alinhamento, grupos e maximos, ordem, grupo e atributos de cada particao, tamanho e SHA-256 das particoes intactas | tamanho e SHA-256 da particao trocada (= GSI); posicao das particoes seguintes (= regra do item 4) |

Qualquer outro desvio, particao desalinhada, sobreposta ou fora da super vira
`INCONSISTÊNCIA! Verifique e corrija os erros` (codigo de saida 1, sem gerar o tar).

## 6. Testes de idempotencia
T1 tar contem `super.img` na raiz · T2 `super.img` do tar == super gerada · T3 md5 do `.tar.md5`
confere · T4 remontagem repetida gera arquivo identico byte a byte · T5 leitura do mapa estavel ·
T6 relatorios gerados.

## O que o script NAO faz
Nao grava nada no aparelho, nao mexe em `vbmeta`, nao garante que a GSI seja compativel com o
vendor, e nao foi testado em layouts A/B virtuais ou com mais de um block device.
