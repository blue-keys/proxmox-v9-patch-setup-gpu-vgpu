# 🚀 Proxmox GPU/vGPU Setup Script

<div align="center">

![Version](https://img.shields.io/badge/version-2.2-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Proxmox](https://img.shields.io/badge/Proxmox-9.0+-orange.svg)
![Bash](https://img.shields.io/badge/bash-5.0+-red.svg)

**Configuration automatisée de GPU passthough et vGPU pour Proxmox VE 9.x | 6.14.8-2-pve | vGPU 19**

[Fonctionnalités](#-fonctionnalités) • [Installation](#-installation) • [Utilisation](#-utilisation) • [Documentation](#-documentation) • [Support](#-support)

</div>

---

## 📋 Table des Matières

- [À propos](#-à-propos)
- [Fonctionnalités](#-fonctionnalités)
- [Prérequis](#-prérequis)
- [Installation](#-installation)
- [Utilisation](#-utilisation)
  - [Mode Interactif](#mode-interactif)
  - [Options en Ligne de Commande](#options-en-ligne-de-commande)
  - [Mode Dry-Run](#mode-dry-run)
- [Étapes de Configuration](#-étapes-de-configuration)
- [Captures d'écran](#-captures-décran)
- [Diagnostic IOMMU](#-diagnostic-iommu)
- [Sauvegarde et Restauration](#-sauvegarde-et-restauration)
- [Dépannage](#-dépannage)
- [FAQ](#-faq)
- [Contribution](#-contribution)
- [Licence](#-licence)
- [Auteur](#-auteur)

---

## 🎯 À propos

Ce script bash à pour but **d'automatise entièrement** la configuration de GPU et vGPU sur Proxmox Virtual Environment 9.x. Il simplifie drastiquement un processus normalement complexe et sujet aux erreurs en offrant une interface interactive intuitive et des validations robustes avec affichages des informations les plus utiles.

### 🌟 Pourquoi ce script ?

- **⏱️ Gain de temps** : Configuration complète en quelques minutes au lieu de plusieurs heures
- **🛡️ Sécurisé** : Sauvegardes automatiques avant toute modification critique
- **🎨 Interface moderne** : Menu interactif avec barres de progression et codes couleur
- **🔍 Diagnostic avancé** : Analyse complète de votre configuration IOMMU/GPU
- **📦 Tout-en-un** : Gère les dépôts, dépendances, IOMMU, pilotes et vGPU
- **🔄 Réversible** : Système de backup/restore complet

---

## ✨ Fonctionnalités

### 🎮 Configuration GPU/vGPU

- ✅ Détection automatique des GPU NVIDIA
- ✅ Configuration IOMMU (Intel VT-d / AMD-Vi)
- ✅ Installation et ❌ configuration des pilotes vGPU
- ❌ Support du passthrough GPU
- ✅ Gestion des modules VFIO

### 🔧 Gestion Système

- ✅ Configuration des dépôts Proxmox (no-subscription)
- ✅ Nettoyage automatique des dépôts enterprise
- ✅ Installation des dépendances requises
- ✅ Mise à jour de initramfs
- ✅ Configuration GRUB automatique

### 🛠️ Outils Avancés

- ✅ **Diagnostic IOMMU complet** avec score de compatibilité
- ✅ **Mode Dry-Run** pour simulation sans modification
- ✅ **Système de sauvegarde/restauration** de configuration
- ✅ **Navigation intelligente** avec option "Passer cette étape"
- ✅ **Gestion des états** pour reprendre après redémarrage
- ✅ **Logs détaillés** avec rotation automatique
- ✅ **Vérification de version** avec mise à jour automatique

### 📊 Interface Utilisateur

- ✅ Menu interactif coloré avec icônes Unicode
- ✅ Barres de progression animées
- ✅ Indicateurs visuels d'état (✓ ✗ ⚠ ○)
- ✅ Système d'avertissements centralisé
- ✅ Résumé détaillé des opérations

---

## 🔌 Prérequis

### Matériel

- 🖥️ **Serveur Proxmox VE** avec CPU supportant la virtualisation (Intel VT-x / AMD-V)
- 🎮 **GPU NVIDIA** compatible vGPU (Tesla, Quadro, RTX série professionnelle)
- 💾 **1 GB d'espace disque** minimum
- 🌐 **Connexion Internet** pour téléchargement des paquets

### Logiciel

- 📦 **Proxmox VE 9.0** ou supérieur
- 🐧 **Debian 12 (Bookworm)** ou Debian 13 (Trixie)
- 🔐 **Accès root** au serveur

### BIOS/UEFI

- ✅ **Intel VT-d** ou **AMD-Vi** activé
- ✅ **Virtualisation** activée (VT-x / AMD-V)

---

## 📥 Installation

### Méthode 1 : Téléchargement direct

```bash
# Télécharger le script
wget https://raw.githubusercontent.com/bluekeys/proxmox-gpu/main/proxmox_patch_bluekeys_V2.2.sh

# Rendre exécutable
chmod +x proxmox_patch_bluekeys_V2.2.sh

# Exécuter
sudo ./proxmox_patch_bluekeys_V2.2.sh
```

### Méthode 2 : Clone du dépôt

```bash
# Cloner le dépôt
git clone https://github.com/bluekeys/proxmox-gpu.git

# Accéder au répertoire
cd proxmox-gpu

# Rendre exécutable
chmod +x proxmox_patch_bluekeys_V2.2.sh

# Exécuter
sudo ./proxmox_patch_bluekeys_V2.2.sh
```

### Méthode 3 : Installation rapide one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/bluekeys/proxmox-gpu/main/proxmox_patch_bluekeys_V2.2.sh | sudo bash
```

> ⚠️ **Note de sécurité** : Toujours vérifier le contenu d'un script avant de l'exécuter avec des privilèges root !

---

## 🎮 Utilisation

### Mode Interactif

Le script propose un **menu interactif complet** :

```bash
sudo ./proxmox_patch_bluekeys_V2.2.sh
```

**Menu principal :**
1. 🚀 Exécuter toutes les étapes (configuration complète)
2. 🎯 Exécuter des étapes spécifiques
3. 📊 Afficher les informations système
4. 🔍 Diagnostic IOMMU complet
5. 🎮 Configuration vGPU uniquement
6. ✅ Vérifier la configuration actuelle
7. 📋 Afficher le résumé des étapes
8. 📝 Afficher les logs
9. ⚙️ Options avancées
0. 🚪 Quitter

### Options en Ligne de Commande

```bash
# Mode simulation (aucune modification)
sudo ./proxmox_patch_bluekeys_V2.2.sh --dry-run

# Mode automatique (pas de confirmations)
sudo ./proxmox_patch_bluekeys_V2.2.sh --skip-confirmations

# Définir le niveau de log
sudo ./proxmox_patch_bluekeys_V2.2.sh --log-level 0  # 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR

# Combinaison d'options
sudo ./proxmox_patch_bluekeys_V2.2.sh --dry-run --log-level 0

# Afficher l'aide
sudo ./proxmox_patch_bluekeys_V2.2.sh --help
```

### Mode Dry-Run

Le **mode Dry-Run** permet de tester le script sans appliquer aucune modification :

```bash
sudo ./proxmox_patch_bluekeys_V2.2.sh --dry-run
```

- ✅ Simule toutes les opérations
- ✅ Affiche ce qui serait fait
- ✅ Aucun changement sur le système
- ✅ Idéal pour tester avant production

---

## 📝 Étapes de Configuration

Le script effectue les **14 étapes suivantes** :

| # | Étape | Description |
|---|-------|-------------|
| 1 | 💬 Message de bienvenue | Affichage des informations du script |
| 2 | 🖥️ Informations système | Collecte des données matérielles |
| 3 | 🔄 Vérification de version | Check des mises à jour disponibles |
| 4 | 💾 Gestion des états | Reprise d'une session précédente |
| 5 | ✅ Prérequis système | Vérification de l'environnement |
| 6 | 📦 Dépendances | Installation des paquets requis |
| 7 | 🗄️ Configuration dépôts | Setup des sources APT |
| 8 | 📥 Installation paquets | Installation des outils nécessaires |
| 9 | 🗑️ Désinstallation pilote | Suppression pilote NVIDIA standard |
| 10 | 🔧 Configuration IOMMU | Activation VT-d/AMD-Vi |
| 11 | 🎮 Vérification GPU | Détection des cartes graphiques |
| 12 | ⚡ Configuration vGPU | Setup du passthrough GPU |
| 13 | 🔄 Mise à jour initramfs | Régénération de l'image initiale |
| 14 | 🔃 Gestion redémarrage | Redémarrage si nécessaire |

### Navigation dans les Étapes

Le script offre une **navigation flexible** :

- **[n]** Suivant : Passer à l'étape suivante
- **[p]** Précédent : Revenir en arrière
- **[m]** Menu : Retour au menu principal
- **[q]** Quitter : Sortie avec sauvegarde
- **[s]** Skip all : Ignorer toutes les confirmations

---

## 📸 Captures d'écran

### Menu Principal
```
╔═══════════════════════════════════════╗
║   MENU PRINCIPAL                      ║
╚═══════════════════════════════════════╝

1. Exécuter toutes les étapes
2. Exécuter des étapes spécifiques
3. Afficher les informations système
...

╔═══════════════════════════════════════╗
║   ÉTAPES DISPONIBLES                  ║
╚═══════════════════════════════════════╝
✓ 1. Affichage du message de bienvenue
✓ 2. Vérification des informations système
○ 3. Vérification de la version du script
✗ 4. Gestion des états précédents
...
```

### Barre de Progression
```
╔═══════════════════════════════════════╗
║   PROGRESSION: [7/14] 50%             ║
╚═══════════════════════════════════════╝

[████████████████████░░░░░░░░░░░░░░░░░░░░] 50%

Étape actuelle: Configuration des dépôts
```

### Diagnostic IOMMU
```
╔═══════════════════════════════════════╗
║   DIAGNOSTIC IOMMU COMPLET            ║
╚═══════════════════════════════════════╝

🔍 Groupes IOMMU:
   ✓ 47 groupes IOMMU détectés

📋 Messages noyau IOMMU:
   ✓ Intel VT-d activé

🔧 Paramètres noyau:
   ✓ Paramètre IOMMU activé
      intel_iommu=on

💻 Support matériel:
   ✓ Intel VT-x (VMX) supporté

Score IOMMU: 5/5 (100%)
[██████████████████████████████████████████] 100%

✓ IOMMU est CORRECTEMENT ACTIVÉ et FONCTIONNEL
```

---

## 🔍 Diagnostic IOMMU

Le script inclut un **outil de diagnostic complet** pour IOMMU :

### Fonctionnalités du Diagnostic

- 📊 **Score de compatibilité** sur 5 points
- 🎯 **Détection des groupes IOMMU**
- 📋 **Analyse des messages kernel**
- 🔧 **Vérification des paramètres**
- 💻 **Test du support matériel**
- 🔌 **État des modules VFIO**
- 🎮 **Détection des GPU**

### Lancer le Diagnostic

```bash
# Via le menu interactif
Option 4 → Diagnostic IOMMU complet

# Ou directement dans le script
diagnose_iommu
```

### Interprétation du Score

| Score | État | Action |
|-------|------|--------|
| 5/5 | ✅ Parfait | Prêt pour vGPU |
| 4/5 | ⚠️ Bon | Vérifier les détails |
| 3/5 | ⚠️ Moyen | Configuration requise |
| <3/5 | ❌ Insuffisant | BIOS + GRUB requis |

---

## 💾 Sauvegarde et Restauration

Le script intègre un **système de backup complet** :

### Sauvegarde Automatique

Créée automatiquement avant toute modification critique de :
- `/etc/default/grub`
- `/etc/apt/sources.list`
- `/etc/apt/sources.list.d/`
- `/etc/modules`
- `/etc/modprobe.d/`

### Sauvegarde Manuelle

```bash
# Via le menu
Options avancées → Créer une sauvegarde manuelle
```

Les sauvegardes sont stockées dans :
```
./backups/config_backup_YYYYMMDD_HHMMSS.tar.gz
```

### Restauration

```bash
# Via le menu
Options avancées → Restaurer une sauvegarde
```

Le script liste toutes les sauvegardes disponibles avec leur date.

---

## 🔧 Dépannage

### Problèmes Courants

#### ❌ IOMMU non détecté

**Symptôme** : Le diagnostic IOMMU échoue

**Solutions** :
1. Vérifier l'activation dans le BIOS (VT-d / AMD-Vi)
2. Lancer la configuration GRUB automatique
3. Redémarrer le serveur
4. Vérifier avec : `dmesg | grep -i iommu`

#### ❌ GPU non détecté

**Symptôme** : `lspci` ne liste pas le GPU

**Solutions** :
1. Vérifier que le GPU est correctement installé
2. Tester sur un autre slot PCIe
3. Vérifier l'alimentation du GPU
4. Consulter : `lspci -v | grep -i vga`

#### ❌ Erreurs de dépôts APT

**Symptôme** : Erreurs 401 lors de `apt update`

**Solutions** :
1. Utiliser l'option "Nettoyer et réparer les dépôts"
2. Le script nettoie automatiquement les dépôts enterprise
3. Vérifier la connectivité : `ping 8.8.8.8`

#### ❌ initramfs échoue

**Symptôme** : Timeout lors de la mise à jour

**Solutions** :
1. Vérifier l'espace disque : `df -h`
2. Nettoyer les anciens kernels : `apt autoremove`
3. Réessayer manuellement : `update-initramfs -u -k all`

### Logs et Debug

```bash
# Afficher les logs
tail -f /var/log/proxmox_gpu_setup.log

# Mode debug
./proxmox_patch_bluekeys_V2.2.sh --log-level 0

# Vérifier l'état
cat ./proxmox_gpu_state.json | jq
```

---

## ❓ FAQ

### Q: Le script fonctionne-t-il avec Proxmox 8.x ?

**R:** Non, ce script est conçu pour Proxmox VE 9.x. Pour les versions antérieures, consultez les versions précédentes du script.

### Q: Puis-je utiliser le script avec des GPU AMD ?

**R:** Actuellement, le script est optimisé pour les GPU NVIDIA. Le support AMD pourrait être ajouté dans une future version.

### Q: Le mode Dry-Run est-il fiable ?

**R:** Oui, le mode Dry-Run simule toutes les opérations sans effectuer de modifications. C'est idéal pour tester.

### Q: Combien de temps prend la configuration complète ?

**R:** Entre 10 et 30 minutes selon votre connexion Internet et la puissance de votre serveur.

### Q: Le script supporte-t-il plusieurs GPU ?

**R:** Oui, le script détecte et configure automatiquement tous les GPU NVIDIA présents.

### Q: Que faire si le script est interrompu ?

**R:** Le script sauvegarde automatiquement son état. Au redémarrage, il proposera de reprendre là où il s'est arrêté.

### Q: Puis-je revenir en arrière après la configuration ?

**R:** Oui, utilisez la fonction de restauration de sauvegarde dans les options avancées.

### Q: Le script modifie-t-il mon BIOS ?

**R:** Non, le script ne peut pas modifier le BIOS. Vous devez activer VT-d/AMD-Vi manuellement dans le BIOS.

---

## 🤝 Contribution

Les contributions sont les bienvenues ! Voici comment contribuer :

### Signaler un Bug

1. Vérifiez que le bug n'est pas déjà signalé dans les [Issues](https://github.com/bluekeys/proxmox-gpu/issues)
2. Créez une nouvelle issue avec :
   - Description détaillée du problème
   - Étapes pour reproduire
   - Logs pertinents (`/var/log/proxmox_gpu_setup.log`)
   - Version de Proxmox et du script
   - Configuration matérielle

### Proposer une Fonctionnalité

1. Ouvrez une issue avec le tag `enhancement`
2. Décrivez la fonctionnalité souhaitée
3. Expliquez le cas d'usage

### Soumettre une Pull Request

1. Fork le projet
2. Créez une branche (`git checkout -b feature/AmazingFeature`)
3. Committez vos changements (`git commit -m 'Add AmazingFeature'`)
4. Push vers la branche (`git push origin feature/AmazingFeature`)
5. Ouvrez une Pull Request

### Guidelines de Code

- 📝 Commentaires en français pour cohérence
- 🎨 Respecter le style existant
- ✅ Tester sur Proxmox 9.x
- 📚 Mettre à jour la documentation si nécessaire

---

## 📜 Licence

Ce projet est sous licence **MIT** - voir le fichier [LICENSE](LICENSE) pour plus de détails.

```
MIT License

Copyright (c) 2025 bluekeys.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
```

---

## 👨‍💻 Auteur

**bluekeys.org**

- 🌐 Website: [bluekeys.org](https://bluekeys.org)
- 📧 Email: contact@bluekeys.org
- 💼 GitHub: [@bluekeys](https://github.com/bluekeys)

---

## 🌟 Remerciements

- Proxmox Team pour leur excellent hyperviseur
- NVIDIA pour les pilotes vGPU
- La communauté Proxmox pour leurs retours et contributions
- Tous les contributeurs sur internet depuis 1 à 4 ans sur le sujet, les articles de leurs blogs et plus
- Tous les contributeurs du projet

---

## 📊 Statistiques

![GitHub stars](https://img.shields.io/github/stars/bluekeys/proxmox-gpu?style=social)
![GitHub forks](https://img.shields.io/github/forks/bluekeys/proxmox-gpu?style=social)
![GitHub watchers](https://img.shields.io/github/watchers/bluekeys/proxmox-gpu?style=social)

---

## 🗺️ Roadmap

- [ ] Add installation and configuration vgpu_unlock - vgpu_unlock-rs
- [ ] Add passthough auto
- [ ] Pilotes GPU/vGPU RTX 2060
- [ ] Support GPU AMD
- [ ] Interface web optionnelle
- [ ] Configuration multi-GPU avancée
- [ ] Templates de configuration prédéfinis
- [ ] Support de plus de langues
- [ ] Support Proxmox 10.x
- [ ] Intégration avec Ansible/Terraform
- [ ] Tests automatisés

---

## 📞 Support

Besoin d'aide ? Plusieurs options s'offrent à vous :

- 📖 Consultez la [Documentation](https://github.com/bluekeys/proxmox-gpu/wiki)
- 💬 Posez vos questions dans les [Discussions](https://github.com/bluekeys/proxmox-gpu/discussions)
- 🐛 Signalez un bug dans les [Issues](https://github.com/bluekeys/proxmox-gpu/issues)
- 📧 Contactez l'auteur : contact@bluekeys.org
  
**Autres sources utiles :**
- [GitLab - vgpu-proxmox](https://gitlab.com/polloloco/vgpu-proxmox)
- [GitHub - vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs/tree/master)
- [GitHub - vgpu_unlock](https://github.com/DualCoder/vgpu_unlock/tree/master)
- [GitHub - proxmox-vgpu-installer](https://github.com/wvthoog/proxmox-vgpu-installer)
- [GitLab - fastapi-dls](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls)
- [Article - Proxmox vGPU v3](https://wvthoog.nl/proxmox-vgpu-v3/)
- [NVIDIA - Tableau des pilotes Grid](https://cloud.google.com/compute/docs/gpus/grid-drivers-table)
- [Console Mistral - Codestral](https://console.mistral.ai/codestral) (Clé API pour VSCode et Claude Sonnet 4.5)
- [Technonagib](https://technonagib.fr)
- [Vellum AI - Leaderboard LLM](https://www.vellum.ai/llm-leaderboard)
- [WunderTech - GPU Passthrough](https://www.wundertech.net/how-to-set-up-gpu-passthrough-on-proxmox/)
- [Gist - Install NVIDIA Driver](https://gist.github.com/ngoc-minh-do/fcf0a01564ece8be3990d774386b5d0c)
- [NVIDIA - Pilotes](https://www.nvidia.com/en-us/drivers/details/251405/)
- [Proxmox Wiki - NVIDIA vGPU](https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE)
- [Proxmox Wiki - PCI Passthrough](https://pve.proxmox.com/wiki/PCI(e)_Passthrough#_general_requirements)
- [Google Cloud - Tableau des pilotes Grid](https://docs.cloud.google.com/compute/docs/gpus/grid-drivers-table?hl=fr)
- [Google Cloud - Installation des pilotes Grid](https://docs.cloud.google.com/compute/docs/gpus/install-grid-drivers?hl=fr#minimum-driver)
- [NVIDIA - Licensing](https://ui.licensing.nvidia.com/software?globalFilter=linux%20KVM)

---

<div align="center">

**⭐ Si ce projet vous a aidé, n'hésitez pas à lui donner une étoile ! ⭐**

Made with ❤️ by [bluekeys.org](https://bluekeys.org)

</div>
