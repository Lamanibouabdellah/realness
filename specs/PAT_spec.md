/* spec: TASK:spec | fonctionnel: PAF:1.0 */
# PAT Specification

## Objectif
Supprimer tous les fichiers dans le repo.

## Comportement
- Supprime récursivement tous les fichiers et dossiers
- Préserve `.git` et `.gitignore`
- Cible par défaut: répertoire courant
- Accepte un chemin de répertoire en argument
