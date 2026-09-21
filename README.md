# Whiteboard Recorder

App macOS de barre de menu : elle enregistre ta réunion — **micro et audio système
mixés dans un seul fichier** — et l'envoie à [Whiteboard](https://whiteboard.kepochan.com),
qui la transcrit et en fait une note.

Elle remplace `meeting-agent-client-mac`, dont le backend s'éteint.

## L'app vit dans la barre de menu, nulle part ailleurs

Whiteboard Recorder n'a **ni icône dans le Dock, ni fenêtre au lancement** (elle
est `LSUIElement`). Un cercle apparaît dans la barre de menu, en haut de l'écran :
c'est tout ce qu'il y a à voir tant qu'aucun enregistrement n'est en cours. Si tu
la lances et que rien ne semble se passer, c'est normal — cherche le cercle dans
la barre de menu, pas une fenêtre.

## Installation

1. Télécharger `WhiteboardRecorder.zip`, décompresser, glisser l'app dans `/Applications`.
2. Au premier lancement, cliquer sur le cercle dans la barre de menu (clic droit)
   et ouvrir **Préférences…** pour coller une clé API. La clé se crée dans
   Whiteboard, sous **Settings → API keys**, avec les scopes `recordings:read`
   et `recordings:write`.
3. Lancer un premier enregistrement (clic gauche sur le cercle). macOS demande
   alors **deux autorisations**, l'une après l'autre — ni avant, ni au lancement
   de l'app :
   - l'accès au **micro** ;
   - l'accès à la **capture audio des autres applications** (« Enregistrer
     l'audio des autres apps » dans Réglages Système → Confidentialité et
     sécurité).

   Les deux sont nécessaires. Sans la seconde, seule ta propre voix est
   enregistrée : les autres participants de l'appel restent muets sur
   l'enregistrement.

## Utilisation

- **Clic gauche** : démarre l'enregistrement **immédiatement** — rien n'est
  perdu pendant que tu remplis quoi que ce soit — et ouvre par-dessus la fenêtre
  de configuration (workspace, titre, date, langue, visibilité, tags).
- **Clic gauche** à nouveau : arrête l'enregistrement et l'envoie.
- **Clic droit** : durée de l'enregistrement en cours, **Préférences…**, **Quitter**.

L'audio n'est pas conservé sur le serveur : il est supprimé une fois la
transcription faite. L'app garde sa copie locale jusqu'à l'envoi réussi, puis la
supprime.

## En cas d'échec de l'envoi

L'enregistrement local **n'est jamais supprimé** en cas d'échec. Une alerte
propose :

- **Réessayer** (quand un nouvel envoi peut raisonnablement réussir) ;
- **Enregistrer…**, pour choisir où mettre le fichier `.m4a` ;
- **Fermer**.

Si tu fermes l'alerte sans choisir, ou si l'échec vient de l'enregistrement
lui-même (pas de l'envoi), le fichier atterrit automatiquement dans ton dossier
de sauvegarde — `~/Downloads` par défaut, réglable dans les Préférences.

## Clé API

La clé est stockée dans le Trousseau macOS (Keychain), jamais dans les
préférences en clair ni dans un fichier du projet. Elle doit porter les scopes
`recordings:read` et `recordings:write`, et se crée dans Whiteboard sous
**Settings → API keys**.

## Note technique : le bac à sable (sandbox)

L'app garde l'App Sandbox actif (`com.apple.security.app-sandbox`). C'est
possible parce que les *process taps* CoreAudio (`AudioHardwareCreateProcessTap`),
utilisés ici pour capter l'audio système sans extension noyau, **fonctionnent
sous App Sandbox** — un point qu'Apple ne documente pas, et qui a été vérifié
avant d'investir dans le reste de la capture.

## Développement

```bash
swift test         # la logique métier (RecorderCore), sans Xcode
./run.sh            # compile en debug et lance l'app
./build-release.sh  # produit WhiteboardRecorder.app et WhiteboardRecorder.zip
```

Aucune clé API ne doit figurer dans le code, les scripts, ou un commit.
