#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 XaulinXs Foundry
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# =============================================================================
# super_repack.sh - troca a system da super.img Samsung (particoes dinamicas)
# Processo validado no Galaxy A35: extrair -> converter -> mapear -> remontar
# -> relatorios (formato lpdump + extras) -> veredito OK/INCONSISTENCIA.
#
# Dois modos:
#   1) MONTAR  : super original + GSI  ->  mod.img + tar para o Odin
#   2) VALIDAR : compara og.img (original) com uma mod.img (ja pronta)
#
# Regras de arquivos: o script PERGUNTA o caminho de cada arquivo (aceita ~,
# caminho relativo a HOME e Tab). Se o arquivo estiver FORA da home do Termux,
# ele e copiado para a home: super original -> og.img, modificada -> mod.img,
# GSI -> gsi.img. Arquivos que voce informar nunca sao alterados.
#
# Saidas: super_original_lpdump.txt, super_new_lpdump.txt, super_validacao.txt
# Ferramentas: simg2img lpunpack lpmake tar md5sum sha256sum cmp stat file python3
# =============================================================================
SUPER_REPACK_VERSION="1.0.0"
set -o pipefail

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_N=$'\e[0m'
LOG=""; COPIED=(); TMP_FILES=()
_log(){ [ -n "$LOG" ] && [ -d "$(dirname "$LOG")" ] && printf '%s\n' "$*" >> "$LOG"; return 0; }
info(){ printf '%s[INFO]%s %s\n' "$C_C" "$C_N" "$*"; _log "[INFO] $*"; }
ok(){   printf '%s[ OK ]%s %s\n' "$C_G" "$C_N" "$*"; _log "[ OK ] $*"; }
warn(){ printf '%s[AVISO]%s %s\n' "$C_Y" "$C_N" "$*"; _log "[AVISO] $*"; }
die(){  printf '%s[ERRO]%s %s\n' "$C_R" "$C_N" "$*" >&2; _log "[ERRO] $*"; exit 1; }
step(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_N"; _log "== $* =="; }
human(){ awk -v b="$1" 'BEGIN{s="B KiB MiB GiB TiB";split(s,u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i]}'; }
fsize(){ stat -c %s "$1"; }
avail_bytes(){ echo $(( $(df -Pk "$1" | awk 'NR==2{print $4}') * 1024 )); }
rpath(){ realpath -- "$1" 2>/dev/null || readlink -f -- "$1"; }

resolve_path(){
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  p="${p//\'/}"; p="${p//\"/}"   # remove aspas em qualquer posicao do caminho
  case "$p" in
    "") ;;
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    /*) ;;
    *) p="$HOME/$p" ;;
  esac
  printf '%s' "$p"
}

ask_yn(){ # $1=pergunta $2=padrao (s|n)
  local p="$1" d="${2:-s}" a hint="[S/n]"
  [ "$d" = n ] && hint="[s/N]"
  while true; do
    read -r -p "$p $hint " a || die "Entrada encerrada."
    a="${a:-$d}"
    case "${a,,}" in s|sim|y|yes) return 0 ;; n|nao|não|no) return 1 ;; esac
  done
}

ask_file(){ # $1=variavel $2=descricao $3=exemplo
  local __v="$1" desc="$2" ex="$3" ans path
  while true; do
    printf '\n%s\n  ex.: %s\n' "$desc" "$ex"
    read -r -e -p "  caminho > " ans || die "Entrada encerrada."
    [ -z "$ans" ] && { warn "Informe um caminho (Ctrl+C para sair)."; continue; }
    path=$(resolve_path "$ans")
    [ -f "$path" ] || { warn "Arquivo nao encontrado: $path"; continue; }
    [ -r "$path" ] || { warn "Sem permissao de leitura: $path"; continue; }
    printf '  -> %s\n     %s | %s\n' "$path" "$(human "$(fsize "$path")")" "$(file -b "$path" | cut -c1-90)"
    if ask_yn "  E este arquivo?" s; then printf -v "$__v" '%s' "$path"; return 0; fi
  done
}

ask_dir(){ # $1=variavel $2=descricao $3=exemplo
  local __v="$1" desc="$2" ex="$3" ans path
  while true; do
    printf '\n%s\n  ex.: %s\n' "$desc" "$ex"
    read -r -e -p "  caminho > " ans || die "Entrada encerrada."
    [ -z "$ans" ] && { warn "Informe um caminho (Ctrl+C para sair)."; continue; }
    path=$(resolve_path "$ans"); path="${path%/}"
    if [ -e "$path" ] && [ ! -d "$path" ]; then warn "Existe e nao e pasta: $path"; continue; fi
    printf '  -> %s\n' "$path"
    if [ ! -d "$path" ]; then
      ask_yn "  A pasta nao existe. Criar?" s || continue
      mkdir -p "$path" || { warn "Nao consegui criar."; continue; }
    else
      ask_yn "  Usar esta pasta?" s || continue
    fi
    [ -w "$path" ] || { warn "Sem permissao de escrita em $path"; continue; }
    printf -v "$__v" '%s' "$path"; return 0
  done
}

ask_outfile(){ # $1=variavel $2=descricao $3=exemplo (.tar a criar)
  local __v="$1" desc="$2" ex="$3" ans path dir
  while true; do
    printf '\n%s\n  ex.: %s\n' "$desc" "$ex"
    read -r -e -p "  caminho > " ans || die "Entrada encerrada."
    [ -z "$ans" ] && { warn "Informe um caminho (Ctrl+C para sair)."; continue; }
    path=$(resolve_path "$ans"); path="${path%.md5}"
    case "$path" in *.tar) ;; *) path="$path.tar" ;; esac
    dir=$(dirname "$path")
    if [ ! -d "$dir" ]; then ask_yn "  A pasta $dir nao existe. Criar?" s && mkdir -p "$dir" || continue; fi
    [ -w "$dir" ] || { warn "Sem permissao de escrita em $dir"; continue; }
    printf '  -> %s\n' "$path"
    if [ -e "$path" ] || [ -e "$path.md5" ]; then ask_yn "  Ja existe. Sobrescrever?" n || continue; fi
    printf -v "$__v" '%s' "$path"; return 0
  done
}

in_home(){ local r h; r=$(rpath "$1"); h=$(rpath "$HOME"); case "$r" in "$h"/*) return 0 ;; esac; return 1; }

# pergunta o caminho; se estiver fora da home do Termux copia como og.img / mod.img / gsi.img
ingest(){ # $1=variavel $2=descricao $3=exemplo $4=og|mod|gsi
  local __v="$1" src ft target sz
  ask_file src "$2" "$3"
  ft=$(file -b "$src")
  case "$4" in
    og)  target="$HOME/og.img";  grep -qi "LZ4" <<<"$ft" && target="$HOME/og.img.lz4" ;;
    mod) target="$HOME/mod.img" ;;
    gsi) target="$HOME/gsi.img"; grep -qi "XZ compressed" <<<"$ft" && target="$HOME/gsi.img.xz"
         grep -qi "gzip compressed" <<<"$ft" && target="$HOME/gsi.img.gz" ;;
  esac
  if in_home "$src"; then
    info "Ja esta na home do Termux; usando no lugar: $src"
    printf -v "$__v" '%s' "$src"; return 0
  fi
  sz=$(fsize "$src")
  if [ -f "$target" ] && [ "$(fsize "$target")" = "$sz" ] && cmp -s -n 16777216 "$src" "$target"; then
    if ask_yn "Ja existe $target com o mesmo tamanho. Reutilizar sem copiar de novo?" s; then
      printf -v "$__v" '%s' "$target"; return 0
    fi
  fi
  [ "$(avail_bytes "$HOME")" -gt $(( sz + 536870912 )) ] || die "Sem espaco na home para copiar $(human "$sz")."
  info "Fora da home do Termux: copiando para $target ($(human "$sz"))..."
  cp -f -- "$src" "$target" || die "Falha ao copiar."
  cmp -s -n 16777216 "$src" "$target" || die "Copia nao confere."
  COPIED+=("$target"); ok "Copiado: $target"
  printf -v "$__v" '%s' "$target"
}

# ------------------------------------------------------------------ Python ---
write_python(){
cat > "$LPMAP" << 'PYEOF'
#!/usr/bin/env python3
# lpmap.py map <img> | report <img> <rotulo> <hashes|-> |
#          compare <orig> <nova> <hash_o|-> <hash_n|-> <part> <tam|-> <sha_gsi|->
import struct, sys, os
NEED = 1 << 20

def head(path, n=NEED):
    with open(path, 'rb') as f:
        b = f.read(4)
        f.seek(0)
        if b == b'\x04\x22\x4d\x18':
            sys.exit(f"{path}: arquivo em LZ4 (descomprima antes)")
        if len(b) < 4 or struct.unpack('<I', b)[0] != 0xED26FF3A:
            return f.read(n), 'RAW'
        _, ma, mi, fh, ch, bs, tb, tc, _ = struct.unpack('<IHHHHIIII', f.read(28))
        f.seek(fh)
        out = bytearray()
        for _ in range(tc):
            if len(out) >= n:
                break
            t, _, csz, tsz = struct.unpack('<HHII', f.read(12))
            d = tsz - ch
            if t == 0xCAC1:
                falta = n - len(out)
                out += f.read(min(d, falta))
                if d > falta:
                    break
            elif t == 0xCAC2:
                out += f.read(4) * (csz * bs // 4)
            elif t == 0xCAC3:
                out += b'\0' * (csz * bs)
            else:
                f.read(d)
        return bytes(out[:n]), f'SPARSE ({tb} blocos de {bs} bytes = {tb*bs} bytes)'

def cstr(b):
    return b.split(b'\0')[0].decode(errors='replace')

def parse(path):
    d, kind = head(path)
    if len(d) < 4096 + 8192 + 128:
        sys.exit(f"{path}: arquivo pequeno demais para ser uma super")
    if struct.unpack_from('<I', d, 4096)[0] != 0x616c4467:
        sys.exit(f"{path}: geometria LP invalida (nao e uma super?)")
    mmax, nslots, lbs = struct.unpack_from('<III', d, 4096 + 8 + 32)
    base = 4096 + 8192
    mg, ma, mi, hsz = struct.unpack_from('<IHHI', d, base)
    if mg != 0x414c5030:
        sys.exit(f"{path}: header de metadata invalido")
    p = base + 12 + 32
    tsz = struct.unpack_from('<I', d, p)[0]
    p += 4 + 32
    tabs = [struct.unpack_from('<III', d, p + 12 * i) for i in range(4)]
    flags = struct.unpack_from('<I', d, p + 48)[0] if (mi >= 2 and hsz >= 132) else 0
    t0 = base + hsz
    (po, pn, ps), (eo, en, es), (go, gn, gs), (bo, bn, bsz) = tabs
    bds = []
    for i in range(bn):
        o = t0 + bo + i * bsz
        fl, al, ao, sz = struct.unpack_from('<QIIQ', d, o)
        bds.append(dict(name=cstr(d[o+24:o+60]), first=fl, align=al, off=ao, size=sz,
                        flags=struct.unpack_from('<I', d, o + 60)[0]))
    groups = []
    for i in range(gn):
        o = t0 + go + i * gs
        groups.append(dict(name=cstr(d[o:o+36]), flags=struct.unpack_from('<I', d, o+36)[0],
                           max=struct.unpack_from('<Q', d, o+40)[0]))
    exts = [struct.unpack_from('<QIQI', d, t0 + eo + i * es) for i in range(en)]
    parts = []
    for i in range(pn):
        o = t0 + po + i * ps
        at, fe, ne, gi = struct.unpack_from('<IIII', d, o + 36)
        ex = exts[fe:fe + ne]
        parts.append(dict(name=cstr(d[o:o+36]), attrs=at, group=groups[gi]['name'], extents=ex,
                          size=sum(e[0] for e in ex) * 512, start=ex[0][2] if ex else 0))
    return dict(path=path, kind=kind, disk=os.path.getsize(path), meta_max=mmax, slots=nslots, lbs=lbs,
                ver=f'{ma}.{mi}', hflags=flags, msize=hsz + tsz, bds=bds, groups=groups, parts=parts)

def attr_names(a):
    n = [s for bit, s in ((1, 'readonly'), (2, 'slot-suffixed'), (4, 'updated'), (8, 'disable-vabc')) if a & bit]
    return ','.join(n) or 'none'
def flag_names(f, table):
    n = [s for bit, s in table if f & bit]
    return ','.join(n) or 'none'
HDR = ((1, 'virtual_ab_device'),)
SLOT = ((1, 'slot-suffixed'),)

def load_hashes(p):
    h = {}
    if p and p != '-' and os.path.exists(p):
        for ln in open(p):
            x = ln.split()
            if len(x) == 3:
                h[x[0]] = (int(x[1]), x[2])
    return h

def cmd_map(path):
    r = parse(path)
    if len(r['bds']) != 1:
        sys.exit("super com mais de um block device: nao suportado por este script")
    b = r['bds'][0]
    for k, v in (('SUPER_NAME', b['name']), ('SUPER_SIZE', b['size']), ('ALIGN', b['align']),
                 ('ALIGN_OFF', b['off']), ('FIRST_SECTOR', b['first']), ('META_SIZE', r['meta_max']),
                 ('SLOTS', r['slots']), ('LBS', r['lbs']), ('LPVER', r['ver'])):
        print(f"{k}={v}")
    for g in r['groups']:
        print(f"G {g['name']} {g['max']}")
    for p in r['parts']:
        print(f"P {p['name']} {p['attrs']} {p['group']} {p['size']} {p['start']}")

def cmd_report(path, label, hashfile):
    r = parse(path)
    H = load_hashes(hashfile)
    dn = lambda i: r['bds'][i]['name'] if i < len(r['bds']) else '?'
    o = []
    o += ["Slot 0:", f"Metadata version: {r['ver']}", f"Metadata size: {r['msize']} bytes",
          f"Metadata max size: {r['meta_max']} bytes", f"Metadata slot count: {r['slots']}",
          f"Header flags: {flag_names(r['hflags'], HDR)}", "Partition table:", "------------------------"]
    for p in r['parts']:
        o += [f"  Name: {p['name']}", f"  Group: {p['group']}", f"  Attributes: {attr_names(p['attrs'])}", "  Extents:"]
        cum = 0
        for ns, tt, td, ts in p['extents']:
            if tt == 0:
                o.append(f"    {cum} .. {cum+ns-1} linear {dn(ts)} {td}")
            else:
                o.append(f"    {cum} .. {cum+ns-1} zero")
            cum += ns
        o.append("------------------------")
    o += ["Super partition layout:", "------------------------"]
    lay = []
    for p in r['parts']:
        for ns, tt, td, ts in p['extents']:
            if tt == 0:
                lay.append((td, ns, p['name'], dn(ts)))
    for td, ns, nm, dv in sorted(lay):
        o.append(f"{dv}: {td} .. {td+ns}: {nm} ({ns} sectors)")
    o += ["------------------------", "Block device table:", "------------------------"]
    for b in r['bds']:
        o += [f"  Partition name: {b['name']}", f"  First sector: {b['first']}", f"  Size: {b['size']} bytes",
              f"  Flags: {flag_names(b['flags'], SLOT)}", "------------------------"]
    o += ["Group table:", "------------------------"]
    for g in r['groups']:
        o += [f"  Name: {g['name']}", f"  Maximum size: {g['max']} bytes", f"  Flags: {flag_names(g['flags'], SLOT)}",
              "------------------------"]
    b = r['bds'][0]
    o += ["", "=========== INFORMACOES ADICIONAIS (super_repack) ===========",
          f"Rotulo: {label}", f"Arquivo: {r['path']}", f"Formato: {r['kind']}",
          f"Tamanho do arquivo em disco: {r['disk']} bytes",
          f"Geometria: logical_block_size={r['lbs']} metadata_max_size={r['meta_max']} slots={r['slots']}",
          f"Alinhamento: {b['align']} bytes ({b['align']//512} setores) | deslocamento: {b['off']} bytes",
          f"Primeiro setor utilizavel: {b['first']} | tamanho da super: {b['size']} bytes",
          "", "Imagens internas (particoes):",
          f"{'nome':<14}{'bytes':>14}{'MiB':>11}{'setor_ini':>12}{'byte_ini':>15}  alinhada  sha256"]
    al = b['align'] or 512
    for p in r['parts']:
        sha = '(nao calculado)'
        if p['name'] in H:
            ln, sh = H[p['name']]
            sha = sh + ('' if ln == p['size'] else f' (primeiros {ln} bytes)')
        ali = 'sim' if (p['size'] == 0 or (p['start'] * 512) % al == 0) else 'NAO'
        o.append(f"{p['name']:<14}{p['size']:>14}{p['size']/1048576:>11.3f}{p['start']:>12}{p['start']*512:>15}  {ali:<8}  {sha}")
    print("\n".join(o))

def align_up(x, a):
    return (x + a - 1) // a * a

def packing(parts, first, asec):
    cur, st = first, []
    for p in parts:
        if p['size'] == 0:
            st.append(0); continue
        st.append(cur); cur = align_up(cur + p['size'] // 512, asec)
    return st

def cmd_compare(a, b, ha, hb, repl, expected, gsisha):
    A, B = parse(a), parse(b)
    HA, HB = load_hashes(ha), load_hashes(hb)
    rows, bad = [], []
    def add(field, x, y, status, prob=None):
        rows.append((field, str(x), str(y), status))
        if prob: bad.append(prob)
    def eq(field, x, y):
        if x == y: add(field, x, y, 'IGUAL')
        else: add(field, x, y, 'DIVERGENTE', f"{field}: {x} -> {y}")
    eq('Metadata version', A['ver'], B['ver'])
    eq('Metadata size (bytes)', A['msize'], B['msize'])
    eq('Metadata max size (bytes)', A['meta_max'], B['meta_max'])
    eq('Metadata slot count', A['slots'], B['slots'])
    eq('Header flags', flag_names(A['hflags'], HDR), flag_names(B['hflags'], HDR))
    eq('Logical block size', A['lbs'], B['lbs'])
    if len(A['bds']) == 1 and len(B['bds']) == 1:
        ba, bb = A['bds'][0], B['bds'][0]
        for k, lab in (('name', 'Super: nome'), ('first', 'Super: primeiro setor'), ('size', 'Super: tamanho (bytes)'),
                       ('align', 'Super: alinhamento (bytes)'), ('off', 'Super: deslocamento'), ('flags', 'Super: flags')):
            eq(lab, flag_names(ba[k], SLOT) if k == 'flags' else ba[k], flag_names(bb[k], SLOT) if k == 'flags' else bb[k])
        align = ba['align'] or 512
        asec = max(1, align // 512)
    else:
        add('Block devices', len(A['bds']), len(B['bds']), 'DIVERGENTE', 'numero de block devices diferente')
        sys.exit(finish(rows, bad))
    ga = {g['name']: g for g in A['groups']}; gb = {g['name']: g for g in B['groups']}
    eq('Grupos (nomes)', ','.join(sorted(ga)), ','.join(sorted(gb)))
    for n in sorted(set(ga) & set(gb)):
        eq(f'Grupo {n}: maximo (bytes)', ga[n]['max'], gb[n]['max'])
        eq(f'Grupo {n}: flags', flag_names(ga[n]['flags'], SLOT), flag_names(gb[n]['flags'], SLOT))
    na, nb = [p['name'] for p in A['parts']], [p['name'] for p in B['parts']]
    eq('Particoes (ordem)', ','.join(na), ','.join(nb))
    if na != nb:
        sys.exit(finish(rows, bad))
    if repl not in na:
        bad.append(f"particao trocada '{repl}' nao existe")
    pa, pb = packing(A['parts'], ba['first'], asec), packing(B['parts'], ba['first'], asec)
    exact = pa == [p['start'] for p in A['parts']]
    rows.append(('Regra de empacotamento do stock', 'alinhado+sequencial' if exact else 'irregular', '-', 'INFO'))
    prev_end = bb['first']; tot = {}
    for i, (x, y) in enumerate(zip(A['parts'], B['parts'])):
        n = x['name']
        eq(f'{n}: grupo', x['group'], y['group'])
        eq(f'{n}: atributos', attr_names(x['attrs']), attr_names(y['attrs']))
        if n == repl:
            if expected != '-':
                if y['size'] == int(expected): add(f'{n}: tamanho (bytes)', x['size'], y['size'], 'ESPERADO (= GSI)')
                else: add(f'{n}: tamanho (bytes)', x['size'], y['size'], 'DIVERGENTE', f"{n}: tamanho {y['size']} != GSI {expected}")
            else:
                add(f'{n}: tamanho (bytes)', x['size'], y['size'], 'ESPERADO (trocada)')
        else:
            eq(f'{n}: tamanho (bytes)', x['size'], y['size'])
        if y['size']:
            if x['start'] == y['start']: add(f'{n}: setor inicial', x['start'], y['start'], 'IGUAL')
            elif (not exact) or y['start'] == pb[i]:
                add(f'{n}: setor inicial', x['start'], y['start'], 'ESPERADO (reposicionada)')
            else:
                add(f'{n}: setor inicial', x['start'], y['start'], 'DIVERGENTE', f"{n}: inicio {y['start']} != previsto {pb[i]}")
            if (y['start'] * 512) % align:
                bad.append(f"{n}: inicio nao alinhado a {align}")
            if y['start'] < prev_end:
                bad.append(f"{n}: sobreposicao (inicio {y['start']} < fim anterior {prev_end})")
            prev_end = y['start'] + y['size'] // 512
        tot[y['group']] = tot.get(y['group'], 0) + y['size']
        if n in HA and n in HB:
            la, sa = HA[n]; lb, sb = HB[n]
            if n == repl:
                if gsisha != '-':
                    if sb == gsisha: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'ESPERADO (= GSI)')
                    else: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'DIVERGENTE', f"{n}: hash difere da GSI")
                elif sa == sb: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'DIVERGENTE', f"{n}: trocada, mas hash igual ao original")
                else: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'ESPERADO (trocada)')
            else:
                if sa == sb and la == lb: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'IGUAL')
                else: add(f'{n}: sha256', sa[:16] + '..', sb[:16] + '..', 'DIVERGENTE', f"{n}: conteudo (hash) diferente do original")
        elif y['size']:
            rows.append((f'{n}: sha256', '-', '-', 'PULADO'))
    if prev_end > bb['size'] // 512:
        bad.append("particoes ultrapassam o tamanho da super")
    for g, t in tot.items():
        if g in gb and gb[g]['max'] and t > gb[g]['max']:
            bad.append(f"grupo {g}: {t} > maximo {gb[g]['max']}")
    sys.exit(finish(rows, bad))

def finish(rows, bad):
    def cut(t, n):
        return t if len(t) <= n else t[:n - 1] + '~'
    w1 = min(34, max([20] + [len(r[0]) + 2 for r in rows]))
    w2 = min(24, max([10] + [len(r[1]) + 2 for r in rows]))
    w3 = min(24, max([10] + [len(r[2]) + 2 for r in rows]))
    print(f"{'CAMPO':<{w1}}{'ORIGINAL':<{w2}}{'REMONTADA':<{w3}}STATUS")
    print('-' * (w1 + w2 + w3 + 24))
    for f, x, y, st in rows:
        print(f"{cut(f, w1 - 1):<{w1}}{cut(x, w2 - 1):<{w2}}{cut(y, w3 - 1):<{w3}}{st}")
    print('-' * (w1 + w2 + w3 + 24))
    if bad:
        print("PROBLEMAS:")
        for x in bad: print("  - " + x)
        print("\nINCONSISTENCIA! Verifique e corrija os erros")
        return 1
    print("\nOK! Faca o Flash")
    return 0

if __name__ == '__main__':
    a = sys.argv
    if len(a) == 3 and a[1] == 'map': cmd_map(a[2])
    elif len(a) == 5 and a[1] == 'report': cmd_report(a[2], a[3], a[4])
    elif len(a) == 9 and a[1] == 'compare': cmd_compare(*a[2:])
    else: sys.exit(__doc__)
PYEOF
}

parse_map(){ # $1=imagem $2=prefixo
  local img="$1" pre="$2" line k v n a g s t m
  eval "${pre}_PN=(); ${pre}_PA=(); ${pre}_PG=(); ${pre}_PS=(); ${pre}_PT=(); ${pre}_GN=(); ${pre}_GM=()"
  while IFS= read -r line; do
    case "$line" in
      "G "*) read -r _ n m <<<"$line"; eval "${pre}_GN+=(\"\$n\"); ${pre}_GM+=(\"\$m\")" ;;
      "P "*) read -r _ n a g s t <<<"$line"
             eval "${pre}_PN+=(\"\$n\"); ${pre}_PA+=(\"\$a\"); ${pre}_PG+=(\"\$g\"); ${pre}_PS+=(\"\$s\"); ${pre}_PT+=(\"\$t\")" ;;
      *=*) k="${line%%=*}"; v="${line#*=}"; printf -v "${pre}_$k" '%s' "$v" ;;
    esac
  done < <("$PY" "$LPMAP" map "$img")
  v="${pre}_SUPER_SIZE"; [ -n "${!v}" ] || return 1
}

print_map(){ # $1=prefixo
  local pre="$1" i
  local -n _PN="${pre}_PN" _PA="${pre}_PA" _PG="${pre}_PG" _PS="${pre}_PS" _PT="${pre}_PT"
  local v1="${pre}_SUPER_SIZE" v2="${pre}_ALIGN" v3="${pre}_FIRST_SECTOR" v4="${pre}_SLOTS" v5="${pre}_META_SIZE"
  printf '  super=%s bytes | alinhamento=%s | primeiro setor=%s | slots=%s | metadata=%s\n' "${!v1}" "${!v2}" "${!v3}" "${!v4}" "${!v5}"
  for i in "${!_PN[@]}"; do
    printf '  %-14s grupo=%-16s attrs=%s tamanho=%-12s inicio=%s\n' "${_PN[$i]}" "${_PG[$i]}" "${_PA[$i]}" "${_PS[$i]}" "${_PT[$i]}"
  done
}

hash_regions(){ # $1=raw $2=prefixo $3=saida $4=particao_trocada $5=bytes_a_hashear_da_trocada
  local raw="$1" pre="$2" out="$3" repl="$4" rl="$5" i nm len st h
  local -n _hPN="${pre}_PN" _hPS="${pre}_PS" _hPT="${pre}_PT"
  : > "$out"
  for i in "${!_hPN[@]}"; do
    nm="${_hPN[$i]}"; len="${_hPS[$i]}"; st="${_hPT[$i]}"
    [ "$len" -gt 0 ] || continue
    [ "$nm" = "$repl" ] && [ -n "$rl" ] && [ "$rl" -lt "$len" ] && len="$rl"
    printf '  sha256 %-12s ' "$nm"
    h=$(tail -c +$(( st * 512 + 1 )) "$raw" | head -c "$len" | sha256sum | cut -d' ' -f1)
    printf '%s\n' "${h:0:16}"
    printf '%s %s %s\n' "$nm" "$len" "$h" >> "$out"
  done
}

expand_if_sparse(){ # $1=img $2=destino ; imprime o caminho do raw (original se ja for raw)
  if file -b "$1" | grep -qi sparse; then simg2img "$1" "$2" || return 1; TMP_FILES+=("$2"); printf '%s' "$2"; else printf '%s' "$1"; fi
}

# --------------------------------------------------------------- remontagem ---
do_build(){ # $1=arquivo de saida
  local out="$1" i n g m used nm sz at img
  local -a args
  args=(--metadata-size "$M_META_SIZE" --metadata-slots "$M_SLOTS"
        --device "$M_SUPER_NAME:$M_SUPER_SIZE:$M_ALIGN:$M_ALIGN_OFF" --super-name "$M_SUPER_NAME")
  for i in "${!M_GN[@]}"; do
    g="${M_GN[$i]}"; m="${M_GM[$i]}"; [ "$g" = default ] && continue
    used=0; for n in "${!M_PN[@]}"; do [ "${M_PG[$n]}" = "$g" ] && used=1; done
    [ "$used" = 1 ] && args+=(--group "$g:$m")
  done
  for i in "${!M_PN[@]}"; do
    nm="${M_PN[$i]}"; sz="${M_PS[$i]}"; at="none"
    [ $(( ${M_PA[$i]} & 1 )) -eq 1 ] && at="readonly"
    if [ "$nm" = "$REPL" ]; then sz="$PART_SIZE"; img="$GSI_RAW"; else img="$PARTS/$nm.img"; fi
    args+=(--partition "$nm:$at:$sz:${M_PG[$i]}")
    [ "$sz" -gt 0 ] && args+=(--image "$nm=$img")
  done
  args+=(--sparse --output "$out")
  _log "lpmake ${args[*]}"
  rm -f "$out"
  lpmake "${args[@]}" 2>&1 | grep -v "Invalid sparse file format" | tee -a "${LOG:-/dev/null}" | tail -n 15
  [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$out" ]
}

cleanup_tmp(){ local f; for f in "${TMP_FILES[@]}"; do [ -n "$f" ] && rm -f "$f"; done; TMP_FILES=(); }
drop_tmp(){ # remove so os arquivos informados (e os tira da lista de temporarios)
  local f x keep t=()
  for f in "$@"; do rm -f "$f"; done
  for x in "${TMP_FILES[@]}"; do keep=1; for f in "$@"; do [ "$x" = "$f" ] && keep=0; done; [ "$keep" = 1 ] && t+=("$x"); done
  TMP_FILES=("${t[@]}")
}
trap 'printf "\n"; warn "Interrompido. Temporarios podem ter ficado em: ${WORK:-?}"; exit 130' INT

show_verdict(){ # $1=arquivo de validacao (tabela completa fica no arquivo)
  local f="$1" ni ne nd
  ni=$(grep -c ' IGUAL$' "$f"); ne=$(grep -c 'ESPERADO' "$f"); nd=$(grep -c 'DIVERGENTE' "$f")
  printf 'Comparacao: %s campos IGUAIS | %s ESPERADOS (mudam como previsto) | %s DIVERGENTES\n' "$ni" "$ne" "$nd"
  grep -E 'ESPERADO|DIVERGENTE' "$f" | grep -v '^PROBLEMAS'
  if grep -q '^PROBLEMAS:' "$f"; then sed -n '/^PROBLEMAS:/,$p' "$f"; else grep '^OK!' "$f"; fi
  printf '(tabela completa em %s)\n' "$f"
}

banner(){ # $1=ok|bad
  if [ "$1" = ok ]; then
    printf '\n%s============================================%s\n%s  OK! Faça o Flash%s\n%s============================================%s\n' "$C_G" "$C_N" "$C_G$C_B" "$C_N" "$C_G" "$C_N"
  else
    printf '\n%s============================================%s\n%s  INCONSISTÊNCIA! Verifique e corrija os erros%s\n%s============================================%s\n' "$C_R" "$C_N" "$C_R$C_B" "$C_N" "$C_R" "$C_N"
  fi
}

# ================================================================== INICIO ===
printf '%s\n' "${C_B}super_repack v$SUPER_REPACK_VERSION - super.img Samsung (particoes dinamicas)${C_N}"
printf 'Cada arquivo e pedido por caminho. Fora da home do Termux, e copiado (og.img / mod.img / gsi.img).\n'

PY=$(command -v python3 || command -v python)
missing=()
for t in simg2img lpunpack lpmake tar md5sum sha256sum cmp stat file awk tail head realpath; do command -v "$t" >/dev/null || missing+=("$t"); done
[ -n "$PY" ] || missing+=("python3")
if [ ${#missing[@]} -gt 0 ]; then
  warn "Ferramentas ausentes: ${missing[*]}"
  warn "Termux: pkg install python file diffutils tar coreutils   (simg2img/lpmake/lpunpack: use as que voce ja tem)"
  die "Instale o que falta e rode de novo."
fi

printf '\nModo:\n  1) MONTAR  - super original + GSI -> mod.img + tar para o Odin (com validacao)\n  2) VALIDAR - comparar og.img (original) com uma mod.img ja pronta\n'
while true; do read -r -p "Escolha [1-2]: " MODE || die "Entrada encerrada."; case "$MODE" in 1|2) break ;; esac; done
ask_yn "Calcular SHA-256 das imagens internas? (relatorio mais completo; mais lento)" s && DOHASH=1 || DOHASH=0

step "Entradas"
ingest OG "Super ORIGINAL (a do firmware stock; sparse/raw ou .lz4):" "~/Super original/original.img" og
if [ "$MODE" = 1 ]; then
  ingest GSI "Imagem NOVA do system (GSI; raw/sparse ou .xz/.gz):" "~/gsi/system.img" gsi
else
  ingest MOD "Super MODIFICADA (a remontada que sera validada):" "~/Super modificada/modificar.img" mod
fi
ask_dir WORK "Pasta de TRABALHO (intermediarios; precisa de espaco):" "~/super_work"
if [ "$MODE" = 1 ]; then
  ask_outfile OUT_TAR "Arquivo de SAIDA (tar para o slot AP do Odin):" "~/super_gsi.tar"
  REPORT_DIR=$(dirname "$OUT_TAR")
  MOD="$HOME/mod.img"
  [ "$(rpath "$OG")" = "$(rpath "$MOD")" ] && die "A super original nao pode ser o mod.img."
  if [ -e "$MOD" ]; then ask_yn "$MOD ja existe e sera substituido pela super remontada. Continuar?" n || die "Cancelado."; fi
else
  ask_dir REPORT_DIR "Pasta onde salvar os relatorios (.txt):" "~/relatorios"
fi
LOG="$WORK/super_repack.log"; : > "$LOG"
LPMAP="$WORK/.lpmap.py"; write_python
PARTS="$WORK/parts"; BUILD="$WORK/build"
rm -rf "$PARTS" "$BUILD"; mkdir -p "$PARTS" "$BUILD"
RP_OG="$REPORT_DIR/super_original_lpdump.txt"; RP_NEW="$REPORT_DIR/super_new_lpdump.txt"; RP_VAL="$REPORT_DIR/super_validacao.txt"

step "Super original"
OG_SRC="$OG"; ft=$(file -b "$OG")
if grep -qi "LZ4" <<<"$ft"; then
  command -v lz4 >/dev/null || die "Super em LZ4: instale o lz4 (pkg install lz4)."
  info "Descomprimindo LZ4..."; lz4 -d -f "$OG" "$WORK/og_dec.img" || die "Falha no lz4."
  OG_SRC="$WORK/og_dec.img"; TMP_FILES+=("$OG_SRC")
fi
parse_map "$OG_SRC" M || die "Nao consegui ler os metadados LP da super original."
print_map M
[ "$M_LBS" = 4096 ] || warn "Logical block size = $M_LBS (fluxo validado com 4096)."

# ------------------------------------------------------------------ MODO 2 ---
if [ "$MODE" = 2 ]; then
  step "Super modificada"
  parse_map "$MOD" N || die "Nao consegui ler os metadados LP da modificada."
  print_map N
  cand=(); for i in "${!M_PN[@]}"; do [ "${M_PS[$i]}" != "${N_PS[$i]}" ] && cand+=("${M_PN[$i]}"); done
  if [ ${#cand[@]} -eq 1 ]; then REPL="${cand[0]}"; info "Particao trocada (pelo tamanho): $REPL"
  else read -r -p "Nome da particao trocada (${M_PN[*]}): " REPL; fi
  ask_yn "Particao trocada = '$REPL'?" s || die "Cancelado."
  OGH="-"; NH="-"
  if [ "$DOHASH" = 1 ]; then
    step "Hashes (expande cada super temporariamente)"
    [ "$(avail_bytes "$WORK")" -gt $(( $(fsize "$OG") + $(fsize "$MOD") )) ] || warn "Pouco espaco livre; pode falhar."
    RAW=$(expand_if_sparse "$OG_SRC" "$WORK/og_raw.img") || die "Falha ao expandir a original."
    info "Original:"; hash_regions "$RAW" M "$WORK/og.hashes" "" ""; drop_tmp "$WORK/og_raw.img"
    RAW=$(expand_if_sparse "$MOD" "$WORK/mod_raw.img") || die "Falha ao expandir a modificada."
    info "Modificada:"; hash_regions "$RAW" N "$WORK/mod.hashes" "" ""; drop_tmp "$WORK/mod_raw.img"
    OGH="$WORK/og.hashes"; NH="$WORK/mod.hashes"
  fi
  step "Relatorios e veredito"
  "$PY" "$LPMAP" report "$OG_SRC" "SUPER ORIGINAL" "$OGH" > "$RP_OG"
  "$PY" "$LPMAP" report "$MOD" "SUPER REMONTADA" "$NH" > "$RP_NEW"
  "$PY" "$LPMAP" compare "$OG_SRC" "$MOD" "$OGH" "$NH" "$REPL" "-" "-" > "$RP_VAL"; rc=$?
  show_verdict "$RP_VAL"; ok "Relatorios: $RP_OG | $RP_NEW | $RP_VAL"
  [ "$rc" -eq 0 ] && { banner ok; exit 0; } || { banner bad; exit 1; }
fi

# ------------------------------------------------------------------ MODO 1 ---
step "Substituicao"
REPL=""; for n in "${M_PN[@]}"; do case "$n" in system|system_a) REPL="$n"; break ;; esac; done
if [ -z "$REPL" ]; then
  read -r -p "Nome da particao a substituir (${M_PN[*]}): " REPL
  found=0; for n in "${M_PN[@]}"; do [ "$n" = "$REPL" ] && found=1; done
  [ "$found" = 1 ] || die "Particao '$REPL' nao existe na super."
fi
ask_yn "Substituir a particao '$REPL' pela GSI?" s || die "Cancelado."
for i in "${!M_PN[@]}"; do [ "${M_PN[$i]}" = "$REPL" ] && REPL_IDX=$i; done

step "Imagem nova do system (GSI)"
GSI_SRC="$GSI"; gt=$(file -b "$GSI")
if grep -qi "XZ compressed" <<<"$gt"; then
  info "Descomprimindo XZ..."; xz -dc "$GSI" > "$WORK/gsi_dec.img" || die "Falha no xz."
  GSI_SRC="$WORK/gsi_dec.img"; TMP_FILES+=("$GSI_SRC"); gt=$(file -b "$GSI_SRC")
elif grep -qi "gzip compressed" <<<"$gt"; then
  info "Descomprimindo GZIP..."; gzip -dc "$GSI" > "$WORK/gsi_dec.img" || die "Falha no gzip."
  GSI_SRC="$WORK/gsi_dec.img"; TMP_FILES+=("$GSI_SRC"); gt=$(file -b "$GSI_SRC")
fi
GSI_RAW="$GSI_SRC"
if grep -qi "sparse" <<<"$gt"; then
  info "Convertendo GSI sparse -> raw..."
  simg2img "$GSI_SRC" "$WORK/gsi_raw.img" || die "Falha no simg2img da GSI."
  GSI_RAW="$WORK/gsi_raw.img"; TMP_FILES+=("$GSI_RAW"); gt=$(file -b "$GSI_RAW")
fi
grep -qiE "ext[234]|erofs|filesystem" <<<"$gt" || warn "Sistema de arquivos nao reconhecido ($gt)."
GSI_SIZE=$(fsize "$GSI_RAW"); PART_SIZE=$(( (GSI_SIZE + 4095) / 4096 * 4096 ))
ok "GSI raw: $GSI_SIZE bytes | particao: $PART_SIZE bytes"
GSI_SHA="-"; [ "$DOHASH" = 1 ] && { info "SHA-256 da GSI..."; GSI_SHA=$(sha256sum "$GSI_RAW" | cut -d' ' -f1); }
if [ "$PART_SIZE" -ne "$GSI_SIZE" ]; then
  warn "Tamanho nao multiplo de 4096: completando com zeros ate $PART_SIZE bytes (copia; o original nao e alterado)."
  cp -f -- "$GSI_RAW" "$WORK/gsi_pad.img" && truncate -s "$PART_SIZE" "$WORK/gsi_pad.img" || die "Falha ao completar a GSI."
  GSI_RAW="$WORK/gsi_pad.img"; TMP_FILES+=("$GSI_RAW")
fi

gm=0; for i in "${!M_GN[@]}"; do [ "${M_GN[$i]}" = "${M_PG[$REPL_IDX]}" ] && gm="${M_GM[$i]}"; done
total=0; for i in "${!M_PN[@]}"; do
  [ "${M_PG[$i]}" = "${M_PG[$REPL_IDX]}" ] || continue
  if [ "$i" = "$REPL_IDX" ]; then total=$((total + PART_SIZE)); else total=$((total + M_PS[i])); fi
done
{ [ "$gm" -gt 0 ] && [ "$total" -gt "$gm" ]; } && die "Particoes do grupo ($total) excedem o maximo ($gm)."
ok "Grupo '${M_PG[$REPL_IDX]}': $total de $gm bytes"
others=0; for i in "${!M_PN[@]}"; do [ "$i" = "$REPL_IDX" ] || others=$((others + M_PS[i])); done
S=$((others + GSI_SIZE)); peak=$(( $(fsize "$OG") + others + GSI_SIZE )); [ $((4*S)) -gt "$peak" ] && peak=$((4*S))
avail=$(avail_bytes "$WORK")
info "Espaco livre: $(human "$avail") | pico estimado: $(human "$peak")"
[ "$avail" -lt "$peak" ] && warn "Espaco possivelmente insuficiente."
ask_yn "Iniciar extracao e remontagem?" s || die "Cancelado."

step "Extracao das particoes que ficam"
OG_RAW="$OG_SRC"
if file -b "$OG_SRC" | grep -qi sparse; then
  info "Convertendo super original sparse -> raw..."
  simg2img "$OG_SRC" "$WORK/og_raw.img" || die "Falha no simg2img."; OG_RAW="$WORK/og_raw.img"; TMP_FILES+=("$OG_RAW")
fi
need=(); for i in "${!M_PN[@]}"; do [ "$i" = "$REPL_IDX" ] && continue; [ "${M_PS[$i]}" -gt 0 ] && need+=("${M_PN[$i]}"); done
pargs=(); for n in "${need[@]}"; do pargs+=(-p "$n"); done
if ! lpunpack "${pargs[@]}" "$OG_RAW" "$PARTS" >>"$LOG" 2>&1; then
  warn "lpunpack sem suporte a -p; extraindo tudo e removendo a particao trocada."
  rm -rf "$PARTS"; mkdir -p "$PARTS"
  lpunpack "$OG_RAW" "$PARTS" >>"$LOG" 2>&1 || die "Falha no lpunpack (veja $LOG)."
  rm -f "$PARTS/$REPL.img"
fi
for i in "${!M_PN[@]}"; do
  [ "$i" = "$REPL_IDX" ] && continue; [ "${M_PS[$i]}" -gt 0 ] || continue
  f="$PARTS/${M_PN[$i]}.img"
  [ -f "$f" ] || die "Particao nao extraida: ${M_PN[$i]}"
  [ "$(fsize "$f")" = "${M_PS[$i]}" ] || die "Tamanho diferente em ${M_PN[$i]}"
  ok "${M_PN[$i]}: ${M_PS[$i]} bytes"
done
OGH="-"
if [ "$DOHASH" = 1 ]; then info "SHA-256 das particoes da super original:"; hash_regions "$OG_RAW" M "$WORK/og.hashes" "" ""; OGH="$WORK/og.hashes"; fi
drop_tmp "$WORK/og_raw.img"; info "Intermediarios da super original removidos."

step "Remontagem (lpmake)"
SUPER="$MOD"
do_build "$SUPER" || die "lpmake falhou (veja $LOG)."
ok "Gerada: $SUPER ($(human "$(fsize "$SUPER")"))"; file -b "$SUPER" | cut -c1-120

step "Conferencia estrutural"
parse_map "$SUPER" N || die "Nao consegui reler a super nova."
print_map N
"$PY" "$LPMAP" compare "$OG_SRC" "$SUPER" "-" "-" "$REPL" "$PART_SIZE" "-" > "$WORK/estrutura.txt"; rc=$?
if [ "$rc" -eq 0 ]; then ok "Estrutura confere com o stock (alinhamento, grupos, atributos, tamanhos e posicoes previstas)."
else show_verdict "$WORK/estrutura.txt"; banner bad; die "Estrutura divergente. NAO grave esta imagem."; fi

step "Conferencia dos dados"
RAW=$(expand_if_sparse "$SUPER" "$WORK/check_raw.img") || die "Falha ao expandir a super nova."
NH="-"
if [ "$DOHASH" = 1 ]; then
  info "SHA-256 das particoes da super remontada:"
  hash_regions "$RAW" N "$WORK/mod.hashes" "$REPL" "$GSI_SIZE"; NH="$WORK/mod.hashes"
else
  for i in "${!N_PN[@]}"; do
    nm="${N_PN[$i]}"; [ "${N_PS[$i]}" -gt 0 ] || continue
    if [ "$nm" = "$REPL" ]; then src="$GSI_RAW"; len="$GSI_SIZE"; else src="$PARTS/$nm.img"; len="${N_PS[$i]}"; fi
    cmp -n "$len" -i "$(( N_PT[i] * 512 )):0" "$RAW" "$src" && ok "dados de $nm identicos" || die "Dados de $nm divergentes. NAO grave."
  done
fi
drop_tmp "$WORK/check_raw.img"

step "Relatorios (formato lpdump + extras) e veredito"
"$PY" "$LPMAP" report "$OG_SRC" "SUPER ORIGINAL" "$OGH" > "$RP_OG"
"$PY" "$LPMAP" report "$SUPER" "SUPER REMONTADA" "$NH" > "$RP_NEW"
"$PY" "$LPMAP" compare "$OG_SRC" "$SUPER" "$OGH" "$NH" "$REPL" "$PART_SIZE" "$GSI_SHA" > "$RP_VAL"; rc=$?
show_verdict "$RP_VAL"; ok "Relatorios: $RP_OG | $RP_NEW | $RP_VAL"
[ "$rc" -eq 0 ] || { banner bad; die "Nao gravar. Corrija as inconsistencias; o tar nao foi gerado."; }
VERDICT_OK=1

step "Empacotamento"
printf 'Formato de saida:\n  1) .tar.md5 (padrao Odin)\n  2) .tar puro\n  3) ambos\n'
while true; do read -r -p "Escolha [1-3] (3): " fmt || die "Entrada encerrada."; fmt="${fmt:-3}"; case "$fmt" in 1|2|3) break ;; esac; done
mkdir -p "$BUILD/pkg"; ln -sf "$SUPER" "$BUILD/pkg/super.img"
tar -chf "$OUT_TAR" -C "$BUILD/pkg" super.img || die "Falha no tar."
ok "tar: $OUT_TAR ($(fsize "$OUT_TAR") bytes)"
MD5F="$OUT_TAR.md5"
if [ "$fmt" != 2 ]; then
  cp "$OUT_TAR" "$MD5F" || die "Falha ao copiar para .md5"
  md5sum -t "$OUT_TAR" >> "$MD5F"; ok "md5: $MD5F ($(fsize "$MD5F") bytes)"
fi

step "Testes de idempotencia"
PASS=0; FAILS=0
res(){ if [ "$1" = ok ]; then ok "PASS  $2"; PASS=$((PASS+1)); else printf '%s[FAIL]%s %s\n' "$C_R" "$C_N" "$2"; _log "[FAIL] $2"; FAILS=$((FAILS+1)); fi; }
tar -tf "$OUT_TAR" | grep -qx "super.img" && res ok "T1 tar contem 'super.img' na raiz" || res no "T1 tar contem 'super.img' na raiz"
tar -xOf "$OUT_TAR" super.img | cmp -s - "$SUPER" && res ok "T2 super.img dentro do tar == super gerada" || res no "T2 super.img dentro do tar == super gerada"
if [ "$fmt" != 2 ]; then
  tl=$(tail -c 300 "$MD5F" | tr -d '\0' | tail -n 1 | tr -d '\r'); th="${tl%% *}"; hl=${#tl}; body=$(( $(fsize "$MD5F") - hl - 1 ))
  [ "$(head -c "$body" "$MD5F" | md5sum | cut -d' ' -f1)" = "$th" ] && res ok "T3 md5 do final do .tar.md5 confere ($th)" || res no "T3 md5 do final do .tar.md5"
fi
if [ "$(avail_bytes "$WORK")" -gt $(( $(fsize "$SUPER") + 1073741824 )) ]; then
  info "T4 remontando pela segunda vez com as mesmas entradas..."
  if do_build "$BUILD/super_2.img" >/dev/null 2>&1 && cmp -s "$SUPER" "$BUILD/super_2.img"; then res ok "T4 remontagem repetida gera arquivo identico (byte a byte)"; else res no "T4 remontagem repetida"; fi
  rm -f "$BUILD/super_2.img"
else warn "T4 pulado: pouco espaco livre."; fi
[ "$("$PY" "$LPMAP" map "$SUPER" | sha256sum)" = "$("$PY" "$LPMAP" map "$SUPER" | sha256sum)" ] && res ok "T5 leitura do mapa estavel" || res no "T5 leitura do mapa estavel"
[ -s "$RP_OG" ] && [ -s "$RP_NEW" ] && [ -s "$RP_VAL" ] && res ok "T6 relatorios gerados" || res no "T6 relatorios gerados"
[ "$fmt" = 1 ] && rm -f "$OUT_TAR"
cleanup_tmp
printf '\n%sTestes: %d PASS, %d FAIL%s\n' "$C_B" "$PASS" "$FAILS" "$C_N"

step "Limpeza"
ask_yn "Apagar a pasta de trabalho ($WORK)?" n && { rm -rf "$WORK"; ok "Pasta de trabalho removida."; } || info "Mantida. Log: $LOG"
if [ ${#COPIED[@]} -gt 0 ]; then
  ask_yn "Apagar as copias feitas na home (${COPIED[*]##*/})?" n && { rm -f "${COPIED[@]}"; ok "Copias removidas."; }
fi

printf '\n%sSaidas:%s\n' "$C_B" "$C_N"
for f in "$MOD" "$OUT_TAR" "$OUT_TAR.md5" "$RP_OG" "$RP_NEW" "$RP_VAL"; do [ -f "$f" ] && printf '  %s (%s bytes)\n' "$f" "$(fsize "$f")"; done
if [ "$FAILS" -eq 0 ] && [ "${VERDICT_OK:-0}" = 1 ]; then
  banner ok; printf 'Lembretes: grave so pelo slot AP; tenha o firmware stock completo a mao;\nmuitas GSIs exigem limpar /data no primeiro boot.\n'
else banner bad; exit 1; fi
