"""
shared/workspace.py

Utilitaires pour parser les réponses LLM et écrire des fichiers dans /workspace.

Convention de format LLM (utilisée par tous les agents qui écrivent du code) :

    SUMMARY: description courte de ce qui a été fait

    ### chemin/vers/fichier.c
    ```c
    // contenu complet du fichier
    ```

    ### autre/fichier.h
    ```c
    // contenu
    ```

    NOTES: commentaires optionnels

Pourquoi ce format ?
  - Simple à générer pour n'importe quel LLM
  - Pas de problème d'échappement JSON avec du code C
  - Lisible directement dans le live feed
"""

import re
import os
from dataclasses import dataclass
from pathlib import Path

WORKSPACE_PATH = Path(os.getenv("WORKSPACE_PATH", "/realness"))


# ─── Modèles ─────────────────────────────────────────────────────────────────

@dataclass
class FileOp:
    path:    str   # relatif au workspace (ex: "src/memory.h")
    content: str   # contenu complet à écrire


# ─── Parsing ─────────────────────────────────────────────────────────────────

# Pattern : ### chemin/fichier.ext  suivi d'un bloc de code ```[lang] ... ```
_FILE_PATTERN = re.compile(
    r'###\s+(\S+)\s*\n```[^\n]*\n(.*?)```',
    re.DOTALL,
)
_DELETE_PATTERN  = re.compile(r'^DELETE:\s*(\S+)', re.IGNORECASE | re.MULTILINE)
_SUMMARY_PATTERN = re.compile(r'SUMMARY:\s*(.+)', re.IGNORECASE)
_NOTES_PATTERN   = re.compile(r'NOTES:\s*(.+)',   re.IGNORECASE | re.DOTALL)


def parse_file_ops(llm_response: str) -> list[FileOp]:
    """
    Extrait toutes les opérations de fichiers depuis une réponse LLM.

    Returns:
        Liste de FileOp (peut être vide si le LLM n'a produit aucun fichier).
    """
    ops = []
    for match in _FILE_PATTERN.finditer(llm_response):
        path    = match.group(1).strip()
        content = match.group(2)          # conserve l'indentation d'origine
        ops.append(FileOp(path=path, content=content))
    return ops


def extract_summary(llm_response: str) -> str:
    """Extrait la ligne SUMMARY: (fallback générique si absente)."""
    match = _SUMMARY_PATTERN.search(llm_response)
    return match.group(1).strip() if match else "modifications apportées"


def extract_notes(llm_response: str) -> str:
    """Extrait le bloc NOTES: (optionnel)."""
    match = _NOTES_PATTERN.search(llm_response)
    if not match:
        return ""
    # Prend seulement la première ligne des notes
    first_line = match.group(1).split("\n")[0].strip()
    return first_line


# ─── Écriture fichiers ───────────────────────────────────────────────────────

def parse_delete_ops(llm_response: str) -> list[str]:
    """
    Extrait les suppressions de fichiers depuis une réponse LLM.
    Pattern reconnu : DELETE: chemin/vers/fichier
    """
    return [m.group(1).strip() for m in _DELETE_PATTERN.finditer(llm_response)]


def apply_file_ops(
    ops: list[FileOp],
    workspace: Path = WORKSPACE_PATH,
) -> list[str]:
    """
    Écrit les fichiers dans le workspace.
    Crée les répertoires intermédiaires si nécessaire.

    Returns:
        Liste des chemins écrits (relatifs au workspace).

    Raises:
        ValueError si un path tente de sortir du workspace (path traversal).
    """
    written = []
    for op in ops:
        target = (workspace / op.path).resolve()
        if not str(target).startswith(str(workspace.resolve())):
            raise ValueError(f"Path interdit (traversal) : {op.path}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(op.content, encoding="utf-8")
        written.append(op.path)
    return written


def apply_delete_ops(
    paths: list[str],
    workspace: Path = WORKSPACE_PATH,
) -> list[str]:
    """
    Supprime les fichiers listés du workspace.

    Returns:
        Liste des chemins supprimés.

    Raises:
        ValueError si un path tente de sortir du workspace.
    """
    deleted = []
    for rel in paths:
        target = (workspace / rel).resolve()
        if not str(target).startswith(str(workspace.resolve())):
            raise ValueError(f"Path interdit (traversal) : {rel}")
        if target.exists():
            target.unlink()
            deleted.append(rel)
            # Supprime le dossier parent s'il est vide
            try:
                target.parent.rmdir()
            except OSError:
                pass  # dossier non vide, on ignore
    return deleted