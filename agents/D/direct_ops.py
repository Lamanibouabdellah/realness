"""
agents/D/direct_ops.py

Interception des commandes filesystem directes pour D.
Exécutées en Python sans passer par le LLM.

Opérations supportées :
  - Suppression fichier  : "supprime src/memory.c"
  - Suppression masse    : "supprime tout sauf les .h"
  - Nettoyage dossier    : "nettoie src/ et garde les .h"
  - Listage              : "liste les fichiers"
  - Création dossier     : "crée le dossier src/net"
  - Renommage            : "renomme src/old.c en src/new.c"

Protection absolue : .git, .gitignore, .gitmodules ne sont JAMAIS supprimés.
"""

import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

WORKSPACE_PATH = Path(os.getenv("WORKSPACE_PATH", "/realness"))

# Fichiers/dossiers jamais supprimés, quoi qu'il arrive
_ALWAYS_KEEP = {".git", ".gitignore"}


@dataclass
class DirectOpResult:
    handled:  bool
    summary:  str       = ""
    deleted:  list[str] = field(default_factory=list)
    written:  list[str] = field(default_factory=list)
    output:   str       = ""


def try_direct_op(instruction: str) -> DirectOpResult:
    """
    Analyse l'instruction et l'exécute directement si c'est une op filesystem.
    Retourne handled=False si c'est du dev C → LLM prend le relais.
    """
    instr = instruction.strip()

    # ── Suppression de masse ──────────────────────────────────────────────────
    # "supprime tout"  /  "supprime tous les fichiers sauf .h"
    # "vide tout"  /  "nettoie tout le repo"
    m = re.match(
        r'(?:supprime?|delete|remove|efface|vide?|nettoie?)\s+'
        r'(?:tout|all|tout\s+le\s+repo|tous\s+les\s+fichiers?)'
        r'(?:\s+(?:sauf|except|hormis)\s+(.+))?$',
        instr, re.IGNORECASE,
    )
    if m:
        keep_raw  = m.group(1).strip() if m.group(1) else None
        keep_exts = _parse_extensions(keep_raw) if keep_raw else set()
        return _clean_folder(".", keep_exts)

    # ── Suppression d'un fichier précis ──────────────────────────────────────
    # "supprime src/memory.c"  /  "delete src/memory.c"
    m = re.match(
        r'(?:supprime?|suppr|delete|remove|efface|enlève?|vire)\s+'
        r'(?:le\s+fichier\s+)?["\']?([^\s"\']+)["\']?\s*$',
        instr, re.IGNORECASE,
    )
    if m:
        return _delete_file(m.group(1).strip())

    # ── Nettoyage d'un dossier avec filtre ───────────────────────────────────
    # "nettoie src/"  /  "nettoie src/ et garde les .h"
    m = re.match(
        r'(?:nettoie?|clean|vide?)\s+(?:le\s+dossier\s+)?["\']?([^\s"\']+)["\']?'
        r'(?:\s+(?:et\s+)?(?:garde|conserve|sauf|keep)\s+(?:seulement\s+)?(?:les\s+)?(.+))?$',
        instr, re.IGNORECASE,
    )
    if m:
        folder    = m.group(1).strip()
        keep_raw  = m.group(2).strip() if m.group(2) else None
        keep_exts = _parse_extensions(keep_raw) if keep_raw else set()
        return _clean_folder(folder, keep_exts)

    # ── Listage des fichiers ──────────────────────────────────────────────────
    if re.match(r'(?:liste?|list|montre|affiche|show|display)\s+', instr, re.IGNORECASE):
        return _list_files()

    # ── Création d'un dossier ─────────────────────────────────────────────────
    m = re.match(
        r'(?:crée?\s+(?:le\s+)?dossier|mkdir)\s+["\']?([^\s"\']+)["\']?\s*$',
        instr, re.IGNORECASE,
    )
    if m:
        return _mkdir(m.group(1).strip())

    # ── Renommage / déplacement ───────────────────────────────────────────────
    m = re.match(
        r'(?:renomme?|déplace?|move|rename)\s+["\']?(\S+)["\']?\s+'
        r'(?:en|vers|to|->)\s+["\']?(\S+)["\']?\s*$',
        instr, re.IGNORECASE,
    )
    if m:
        return _move_file(m.group(1).strip(), m.group(2).strip())

    # Pas une op directe → LLM
    return DirectOpResult(handled=False)


# ─── Opérations ────────────────────────────────────────────────────────────

def _delete_file(rel_path: str) -> DirectOpResult:
    if rel_path in _ALWAYS_KEEP:
        return DirectOpResult(handled=True, summary="Interdit",
                              output=f"❌ Fichier protégé : {rel_path}")
    target = _safe_resolve(rel_path)
    if target is None:
        return DirectOpResult(handled=True, summary="Erreur",
                              output=f"❌ Path interdit : {rel_path}")
    if not target.exists():
        return DirectOpResult(handled=True, summary=f"Fichier introuvable : {rel_path}",
                              output=f"⚠️  Fichier introuvable : {rel_path}")

    target.unlink()
    _rmdir_if_empty(target.parent)

    return DirectOpResult(
        handled=True,
        summary=f"Suppression de {rel_path}",
        deleted=[rel_path],
        output=f"✓ Supprimé : {rel_path}",
    )


def _clean_folder(folder: str, keep_exts: set[str]) -> DirectOpResult:
    target = _safe_resolve(folder)
    if target is None:
        return DirectOpResult(handled=True, summary="Erreur",
                              output=f"❌ Path interdit : {folder}")
    if not target.exists() or not target.is_dir():
        return DirectOpResult(handled=True, summary=f"Dossier introuvable : {folder}",
                              output=f"⚠️  Dossier introuvable : {folder}")

    deleted = []
    for f in sorted(target.rglob("*")):
        if not f.is_file():
            continue
        # Protection absolue
        if any(part in _ALWAYS_KEEP for part in f.parts):
            continue
        if f.name in _ALWAYS_KEEP:
            continue
        # Filtre keep
        if keep_exts and f.suffix.lower() in keep_exts:
            continue
        rel = str(f.relative_to(WORKSPACE_PATH))
        safe = _safe_resolve(rel)
        if safe is None:
            continue
        f.unlink()
        deleted.append(rel)

    # Supprime les dossiers vides
    for d in sorted(target.rglob("*"), reverse=True):
        if d.is_dir():
            _rmdir_if_empty(d)

    summary = f"Nettoyage de {folder}"
    if keep_exts:
        summary += f" (conservé : {', '.join(sorted(keep_exts))})"

    output = f"✓ {len(deleted)} fichier(s) supprimé(s)"
    if deleted:
        output += " : " + ", ".join(deleted[:8])
        if len(deleted) > 8:
            output += f" ... +{len(deleted) - 8}"

    return DirectOpResult(handled=True, summary=summary, deleted=deleted, output=output)


def _list_files() -> DirectOpResult:
    files = [
        f for f in sorted(WORKSPACE_PATH.rglob("*"))
        if f.is_file()
        and not any(p in _ALWAYS_KEEP for p in f.parts)
        and "specs" not in str(f)
    ]
    if not files:
        output = "  (workspace vide)"
    else:
        output = "\n".join(f"  {f.relative_to(WORKSPACE_PATH)}" for f in files)

    return DirectOpResult(handled=True, summary="Listage des fichiers", output=output)


def _mkdir(rel_path: str) -> DirectOpResult:
    target = _safe_resolve(rel_path)
    if target is None:
        return DirectOpResult(handled=True, summary="Erreur",
                              output=f"❌ Path interdit : {rel_path}")
    target.mkdir(parents=True, exist_ok=True)
    return DirectOpResult(
        handled=True,
        summary=f"Création dossier {rel_path}",
        output=f"✓ Dossier créé : {rel_path}",
    )


def _move_file(src: str, dst: str) -> DirectOpResult:
    src_path = _safe_resolve(src)
    dst_path = _safe_resolve(dst)
    if src_path is None or dst_path is None:
        return DirectOpResult(handled=True, summary="Erreur", output="❌ Path interdit")
    if not src_path.exists():
        return DirectOpResult(handled=True, summary=f"Fichier introuvable : {src}",
                              output=f"⚠️  Introuvable : {src}")

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src_path), str(dst_path))
    _rmdir_if_empty(src_path.parent)

    return DirectOpResult(
        handled=True,
        summary=f"Renommage {src} → {dst}",
        deleted=[src],
        written=[dst],
        output=f"✓ {src} → {dst}",
    )


# ─── Helpers ───────────────────────────────────────────────────────────────

def _safe_resolve(rel: str) -> Path | None:
    target = (WORKSPACE_PATH / rel).resolve()
    if not str(target).startswith(str(WORKSPACE_PATH.resolve())):
        return None
    return target


def _rmdir_if_empty(d: Path) -> None:
    try:
        d.rmdir()
    except OSError:
        pass


def _parse_extensions(raw: str) -> set[str]:
    return {ext.lower() for ext in re.findall(r'\.[a-zA-Z0-9]+', raw)}