# Geheimnisse aus <NAME>_FILE (Docker/Kubernetes-Secrets) vor allen anderen Modulen übernehmen
from .config import load_secret_files

load_secret_files()
