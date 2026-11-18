#!/usr/bin/env python3
"""Comprobación rápida de deriva entre las specs y el código de un proyecto.

Solo lee. Sin dependencias: python3 del sistema y, si hay, git.

    python3 sdd-deriva.py [raíz] [--specs DIR] [--desde REF] [--detalle]
                          [--estricto] [--json]

Qué mira:
  1. Dónde están las specs y de qué formato son.
  2. Enlaces rotos entre las specs y hacia el código.            (error)
  3. Identificadores definidos dos veces o citados sin definir.  (error)
  4. Archivos de código que ninguna spec nombra.                 (aviso)
  5. Requisitos que ni las pruebas ni la trazabilidad nombran.   (informativo)
  6. Specs que nadie enlaza y cambios a medias.                  (aviso)

No entiende el contenido: que no encuentre nada no dice que las specs sean
ciertas.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from urllib.parse import unquote

FORMATOS = [
    ("docs/specs", "SDD propio (docs/specs)"),
    ("specs", "SDD propio o Spec Kit (specs/)"),
    ("openspec", "OpenSpec"),
    (".kiro/specs", "Kiro"),
    (".claude/specs", "claude-code-spec-workflow"),
    ("agent-os/specs", "Agent OS"),
    ("docs/sdd", "SDD propio (docs/sdd)"),
]
CODIGO = {
    ".swift", ".cs", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".go",
    ".rs", ".java", ".kt", ".rb", ".php", ".c", ".cc", ".cpp", ".h", ".hpp",
    ".m", ".mm", ".sh", ".sql", ".vue", ".svelte", ".dart", ".lua", ".ex",
}
SALTAR_DIR = {
    "node_modules", "vendor", "dist", "build", ".build", "out", "target",
    ".git", "__pycache__", ".venv", "venv", "Pods", "DerivedData", "bin",
    "obj", ".next", ".wrangler", "coverage", "third_party", ".claude",
}
RE_PRUEBA = re.compile(
    r"(^|/)(tests?|Tests|__tests__|spec|Checks|fixtures|e2e)(/|$)|"
    r"(^|/)test[-_][^/]*$|[-_.](test|spec|checks?)\.[a-z]+$|Tests?\.[a-z]+$|"
    r"Checks\.[a-z]+$",
)
RE_ID = re.compile(r"(?<![A-Za-z0-9-])([A-Z]{2,6})-(\d{1,4})(?:-([A-Z]{1,3})(\d{1,4}))?(?![A-Za-z0-9])")
RE_ENLACE = re.compile(r"(?<!!)\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
RE_VALLA = re.compile(r"^\s*(```|~~~)")
PREFIJOS_REQ = {"FR", "RF", "REQ", "R", "NFR"}
MAX_BYTES = 2_000_000


def leer(ruta):
    try:
        if os.path.getsize(ruta) > MAX_BYTES:
            return ""
        with open(ruta, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def git(raiz, *args):
    try:
        r = subprocess.run(["git", "-C", raiz, *args], capture_output=True,
                           text=True, timeout=60)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def listar_archivos(raiz):
    """Rutas relativas de los archivos del proyecto (git si hay; si no, disco)."""
    salida = git(raiz, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if salida is not None:
        rutas = [p for p in salida.split("\0") if p]
    else:
        rutas = []
        for base, dirs, nombres in os.walk(raiz):
            dirs[:] = [d for d in dirs if d not in SALTAR_DIR]
            for n in nombres:
                rutas.append(os.path.relpath(os.path.join(base, n), raiz))
    return [p for p in rutas
            if not (set(p.split("/")[:-1]) & SALTAR_DIR) and os.path.isfile(os.path.join(raiz, p))]


def detectar(raiz, forzado):
    if forzado:
        return [(forzado, "indicado con --specs")]
    hallados = []
    for rel, nombre in FORMATOS:
        d = os.path.join(raiz, rel)
        if os.path.isdir(d) and any(n.endswith(".md") for _, _, ns in os.walk(d) for n in ns):
            hallados.append((rel, nombre))
    if os.path.isdir(os.path.join(raiz, ".specify")):
        hallados.append((".specify", "GitHub Spec Kit (.specify)"))
    if os.path.isdir(os.path.join(raiz, ".kiro/steering")):
        hallados.append((".kiro/steering", "Kiro (steering)"))
    for n in ("SPEC.md", "docs/SPEC.md"):
        if os.path.isfile(os.path.join(raiz, n)):
            hallados.append((n, "nivel mínimo (SPEC.md)"))
    return hallados


def sin_codigo(texto):
    """Líneas del Markdown fuera de bloques de código, con su número."""
    dentro = False
    for n, linea in enumerate(texto.splitlines(), 1):
        if RE_VALLA.match(linea):
            dentro = not dentro
            continue
        if not dentro:
            yield n, linea


def id_texto(m):
    return m.group(0)


def definicion_en(linea):
    """IDs que esta línea define: primera celda de una fila, título, o viñeta en negrita."""
    s = linea.strip()
    cab = None
    if s.startswith("|"):
        celdas = s.strip("|").split("|")
        cab = celdas[0] if celdas else ""
    elif s.startswith("#"):
        cab = s.lstrip("#")[:40]
    else:
        m = re.match(r"^(?:[-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?\*\*([^*]+)\*\*", s)
        if m:
            cab = m.group(1)
    if cab is None:
        return []
    cab = re.sub(r"[\[\]*`~]", "", cab).strip()
    cab = re.sub(r"\([^)]*\)", "", cab).strip()
    m = RE_ID.match(cab)
    # La celda debe empezar por el ID y no ser un rango ni una lista de varios.
    if m and len(RE_ID.findall(cab)) == 1 and not re.match(r"\s*[–—-]\s*[A-Z0-9]", cab[m.end():]):
        return [id_texto(m)]
    return []


def main():
    ap = argparse.ArgumentParser(description="Deriva entre specs y código (solo lectura).")
    ap.add_argument("raiz", nargs="?", default=".")
    ap.add_argument("--specs", help="carpeta o archivo de specs, relativo a la raíz")
    ap.add_argument("--desde", help="solo archivos de código añadidos desde este commit o rama")
    ap.add_argument("--detalle", action="store_true", help="listar todo, sin resumir")
    ap.add_argument("--estricto", action="store_true", help="salir con 1 si hay errores")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    raiz = os.path.abspath(a.raiz)
    if not os.path.isdir(raiz):
        print(f"No existe la carpeta: {raiz}", file=sys.stderr)
        return 2
    arriba = git(raiz, "rev-parse", "--show-toplevel")
    if arriba and not a.specs and not detectar(raiz, None):
        raiz = arriba.strip() or raiz

    hallados = detectar(raiz, a.specs)
    archivos = listar_archivos(raiz)
    inf = {"raiz": raiz, "formatos": [{"ruta": r, "formato": n} for r, n in hallados],
           "commit": (git(raiz, "rev-parse", "--short", "HEAD") or "").strip() or None}

    if not hallados:
        codigo = [p for p in archivos if os.path.splitext(p)[1] in CODIGO]
        inf["sin_sdd"] = True
        inf["archivos_codigo"] = len(codigo)
        if a.json:
            print(json.dumps(inf, ensure_ascii=False, indent=2))
        else:
            print(f"Proyecto: {raiz}")
            print("SDD: no encontrado (docs/specs, specs, .specify, openspec, .kiro, SPEC.md).")
            print(f"Código: {len(codigo)} archivos. Siguiente paso: crear la línea base "
                  "(referencias/linea-base.md) o la base de un proyecto nuevo.")
        return 0

    # --- Archivos de specs -------------------------------------------------
    specs = []
    for rel, _ in hallados:
        abs_ = os.path.join(raiz, rel)
        if os.path.isfile(abs_):
            specs.append(rel)
        else:
            pref = rel.rstrip("/") + "/"
            specs += [p for p in archivos if p.startswith(pref) and p.endswith(".md")]
    specs = sorted(set(specs))
    textos = {p: leer(os.path.join(raiz, p)) for p in specs}
    todo_specs = "\n".join(textos.values())
    inf["specs"] = len(specs)

    # --- Enlaces -----------------------------------------------------------
    rotos, enlazados = [], set()
    for p, t in textos.items():
        base = os.path.dirname(os.path.join(raiz, p))
        for n, linea in sin_codigo(t):
            for m in RE_ENLACE.finditer(linea):
                dest = m.group(1).strip("<>")
                if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", dest) or dest.startswith("#"):
                    continue
                dest = unquote(dest.split("#")[0].split("?")[0])
                if not dest or "‹" in dest or dest.startswith("ruta/"):
                    continue
                abs_ = os.path.normpath(os.path.join(raiz, dest.lstrip("/")) if dest.startswith("/")
                                        else os.path.join(base, dest))
                if os.path.exists(abs_):
                    enlazados.add(os.path.relpath(abs_, raiz))
                else:
                    rotos.append({"archivo": p, "linea": n, "destino": m.group(1)})
    inf["enlaces_rotos"] = rotos

    # --- Identificadores ---------------------------------------------------
    defs = defaultdict(list)       # id -> [(archivo, línea)]
    citas = defaultdict(list)
    for p, t in textos.items():
        for m in RE_ID.finditer(os.path.basename(p)):
            if os.path.basename(p).startswith(m.group(0)):
                defs[id_texto(m)].append((p, 0))
        for parte in p.split("/")[:-1]:
            m = RE_ID.fullmatch(parte)
            if m and (p, 0) not in defs[parte]:
                defs[parte].append((p, 0))
        for n, linea in sin_codigo(t):
            propios = definicion_en(linea)
            for i in propios:
                defs[i].append((p, n))
            for m in RE_ID.finditer(linea):
                if id_texto(m) not in propios:
                    citas[id_texto(m)].append((p, n))

    def calificado(i):
        return RE_ID.fullmatch(i).group(3) is not None

    duplicados = []
    for i, lugares in sorted(defs.items()):
        reales = [(p, n) for p, n in lugares if n > 0]
        if calificado(i):
            if len(reales) > 1:
                duplicados.append({"id": i, "lugares": [f"{p}:{n}" for p, n in reales]})
        else:  # un ID corto (AC-01, CAM-001) puede ser local: solo choca dentro del archivo
            por_archivo = defaultdict(list)
            for p, n in reales:
                por_archivo[p].append(n)
            for p, ns in por_archivo.items():
                # título + fila de índice en el mismo archivo no es un choque
                tablas = [n for n in ns if textos[p].splitlines()[n - 1].lstrip().startswith("|")]
                if len(tablas) > 1:
                    duplicados.append({"id": i, "lugares": [f"{p}:{n}" for n in tablas]})
    inf["ids_duplicados"] = duplicados

    prefijos = {RE_ID.fullmatch(i).group(1) for i in defs}
    # Solo se exige definición a los prefijos que el proyecto define de verdad
    # (así SHA-256 o UTF-8 no cuentan) y a los que tienen forma de requisito.
    huerfanos = []
    for i, lugares in sorted(citas.items()):
        m = RE_ID.fullmatch(i)
        if i in defs or m.group(1) not in prefijos:
            continue
        if not calificado(i) and m.group(1) in {"AC", "CA", "T", "US", "SC"}:
            continue
        nivel_def = any(calificado(d) == calificado(i) and d.startswith(m.group(1) + "-") for d in defs)
        if nivel_def:
            huerfanos.append({"id": i, "lugares": [f"{p}:{n}" for p, n in lugares[:3]]})
    inf["ids_sin_definir"] = huerfanos
    inf["ids_definidos"] = len(defs)

    # --- Requisitos sin prueba ---------------------------------------------
    def es_requisito(i):
        m = RE_ID.fullmatch(i)
        if m.group(3):
            return m.group(3).startswith("R")
        return m.group(1) in PREFIJOS_REQ

    requisitos = sorted(i for i in defs if es_requisito(i))
    pruebas = [p for p in archivos if RE_PRUEBA.search(p) and p not in textos
               and os.path.splitext(p)[1] in CODIGO | {".json", ".yaml", ".yml", ".txt"}]
    texto_pruebas = set()
    if requisitos:
        for p in pruebas:
            texto_pruebas.update(m.group(0) for m in RE_ID.finditer(leer(os.path.join(raiz, p))))
    traza = [p for p in specs if re.search(r"trazab|traceab|evidenc|verificac", os.path.basename(p), re.I)]
    for p in specs:
        if os.path.basename(p).lower() in ("tasks.md", "tareas.md"):
            traza.append(p)
    en_traza = set()
    for p in traza:
        for n, linea in sin_codigo(textos[p]):
            propios = definicion_en(linea)
            en_traza.update(id_texto(m) for m in RE_ID.finditer(linea) if id_texto(m) not in propios)
    sin_prueba = [i for i in requisitos if i not in texto_pruebas and i not in en_traza]
    inf["requisitos"] = len(requisitos)
    inf["requisitos_sin_prueba"] = sin_prueba if a.detalle or a.json else len(sin_prueba)
    inf["archivos_de_prueba"] = len(pruebas)
    inf["archivos_de_trazabilidad"] = traza

    # --- Código sin spec ---------------------------------------------------
    codigo = [p for p in archivos if os.path.splitext(p)[1] in CODIGO
              and not RE_PRUEBA.search(p) and not p.endswith(".min.js")]
    if a.desde:
        salida = git(raiz, "diff", "--name-only", "--diff-filter=A", f"{a.desde}...HEAD")
        nuevos = set((salida or "").split("\n"))
        nuevos |= set((git(raiz, "ls-files", "--others", "--exclude-standard") or "").split("\n"))
        if salida is None:
            print(f"Aviso: no se pudo comparar con «{a.desde}»; se miran todos los archivos.",
                  file=sys.stderr)
        else:
            codigo = [p for p in codigo if p in nuevos]
    palabras = set(re.findall(r"[A-Za-z_][A-Za-z0-9_+.-]*", todo_specs))
    carpetas = set(re.findall(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*/", todo_specs))
    carpetas = {c for c in carpetas if c.strip("/") not in ("", ".", "..")}
    def nombrado(p):
        nombre = os.path.basename(p)
        return (p in enlazados or nombre in palabras
                or os.path.splitext(nombre)[0] in palabras or p in todo_specs)

    # Una carpeta citada cubre sus archivos solo si la spec la trata como una
    # unidad: si nombra archivos sueltos de ella, los demás cuentan como sin spec.
    con_nombrados = {os.path.dirname(p) + "/" for p in codigo if nombrado(p)}
    sin_spec = []
    for p in codigo:
        if nombrado(p):
            continue
        padre = os.path.dirname(p) + "/"
        if padre not in con_nombrados and any(padre == c or padre.endswith("/" + c) for c in carpetas):
            continue
        sin_spec.append(p)
    por_carpeta = defaultdict(list)
    for p in sin_spec:
        por_carpeta[os.path.dirname(p) or "."].append(os.path.basename(p))
    inf["codigo"] = len(codigo)
    inf["codigo_sin_spec"] = {k: v for k, v in sorted(por_carpeta.items())}

    # --- Specs que nadie enlaza y cambios a medias --------------------------
    sueltas = [p for p in specs if p not in enlazados and len(specs) > 1
               and os.path.basename(p).lower() not in ("readme.md", "spec.md", "index.md")
               and not os.path.basename(p).lower().startswith("plantilla")
               and not (os.path.basename(p).lower() in ("plan.md", "tasks.md", "design.md", "proposal.md")
                        and os.path.join(os.path.dirname(p), "spec.md") in enlazados)]
    inf["specs_sin_enlazar"] = sueltas
    a_medias = []
    por_dir = defaultdict(set)
    for p in specs:
        por_dir[os.path.dirname(p)].add(os.path.basename(p).lower())
    for d, ns in sorted(por_dir.items()):
        if "spec.md" in ns and d and "/archive/" not in d + "/":
            faltan = [n for n in ("plan.md", "tasks.md") if n not in ns]
            if faltan:
                a_medias.append({"cambio": d, "falta": faltan})
    inf["cambios_incompletos"] = a_medias

    errores = len(rotos) + len(duplicados) + len(huerfanos)
    inf["errores"] = errores

    if a.json:
        print(json.dumps(inf, ensure_ascii=False, indent=2))
        return 1 if (a.estricto and errores) else 0

    # --- Informe -----------------------------------------------------------
    def lista(titulo, filas, tope=12):
        print(f"\n{titulo}: {len(filas)}")
        ver = filas if a.detalle else filas[:tope]
        for f in ver:
            print(f"  - {f}")
        if len(filas) > len(ver):
            print(f"  … y {len(filas) - len(ver)} más (--detalle)")

    print(f"Proyecto: {raiz}" + (f"  (commit {inf['commit']})" if inf["commit"] else ""))
    print("SDD: " + "; ".join(f"{n} en {r}" for r, n in hallados))
    print(f"Specs: {len(specs)} archivos · {len(defs)} identificadores definidos · "
          f"{len(requisitos)} requisitos")

    print("\n== Errores (arreglar ahora) ==")
    lista("Enlaces rotos", [f"{r['archivo']}:{r['linea']} → {r['destino']}" for r in rotos])
    lista("Identificadores definidos más de una vez",
          [f"{d['id']}: {', '.join(d['lugares'])}" for d in duplicados])
    lista("Identificadores citados sin definición",
          [f"{h['id']}: {', '.join(h['lugares'])}" for h in huerfanos])

    print("\n== Avisos (arreglar o anotar como brecha) ==")
    alcance = f"añadidos desde {a.desde}" if a.desde else "del proyecto"
    print(f"\nArchivos de código {alcance} que ninguna spec nombra: "
          f"{len(sin_spec)} de {len(codigo)}")
    orden = sorted(por_carpeta.items(), key=lambda kv: -len(kv[1]))
    for carpeta, ns in (orden if a.detalle else orden[:15]):
        muestra = ", ".join(sorted(ns) if a.detalle else sorted(ns)[:4])
        resto = "" if a.detalle or len(ns) <= 4 else f", … (+{len(ns) - 4})"
        print(f"  - {carpeta}/  ({len(ns)}): {muestra}{resto}")
    if not a.detalle and len(orden) > 15:
        print(f"  … y {len(orden) - 15} carpetas más (--detalle)")
    lista("Specs que ningún otro documento enlaza", sueltas)
    lista("Cambios con spec y sin plan o tareas",
          [f"{c['cambio']}: falta {', '.join(c['falta'])}" for c in a_medias])

    print("\n== Informativo ==")
    if requisitos:
        print(f"\nRequisitos sin mención en pruebas ni en la trazabilidad: "
              f"{len(sin_prueba)} de {len(requisitos)}")
        print(f"  (buscado en {len(pruebas)} archivos de prueba y en: "
              f"{', '.join(traza) if traza else 'ningún archivo de trazabilidad'})")
        if sin_prueba and not a.detalle:
            por_spec = defaultdict(int)
            for i in sin_prueba:
                m = RE_ID.fullmatch(i)
                por_spec[f"{m.group(1)}-{m.group(2)}" if m.group(3) else m.group(1)] += 1
            print("  Por spec: " + ", ".join(f"{k} ({v})" for k, v in sorted(por_spec.items())))
            print("  Con trazabilidad por grupo de casos esto es lo esperado: se une caso a "
                  "caso solo lo que se va a cambiar.")
        elif a.detalle:
            for i in sin_prueba:
                print(f"  - {i}")
    else:
        print("\nNo hay requisitos numerados que comprobar (formato sin identificadores "
              "o specs aún sin requisitos).")

    print(f"\nResumen: {errores} errores, {len(sin_spec)} archivos sin spec, "
          f"{len(sueltas)} specs sueltas, {len(a_medias)} cambios incompletos.")
    return 1 if (a.estricto and errores) else 0


if __name__ == "__main__":
    sys.exit(main())
