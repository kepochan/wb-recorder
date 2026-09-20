# whiteboard-recorder — design

Date : 2026-09-21
Statut : validé, prêt pour le plan d'implémentation

## 1. Objectif

Une app macOS de barre de menu qui enregistre une réunion (micro **et** audio système)
et l'envoie à Whiteboard, qui la transcrit et en fait une note.

Elle remplace `meeting-agent-client-mac`, client de Meeting Agent, backend en cours
d'extinction. Le code de départ existe (~1760 lignes de Swift AppKit, sans tests) mais
n'est pas repris tel quel : nouveau dépôt, historique neuf, l'ancien reste comme archive.

## 2. Périmètre

### Dans le périmètre

- Capture micro + audio système mixés dans un seul `.m4a`.
- Choix, avant chaque enregistrement : workspace, titre, date de réunion, langue,
  visibilité, tags.
- Upload en un appel vers `POST /recordings`.
- Préférences : clé API, workspace par défaut, URL de l'API, IP ESP32, dossier de sauvegarde.
- Intégration ESP32 (écran rouge pendant l'enregistrement), désactivable.

### Hors périmètre — décidé explicitement

Ces choix sont des décisions, pas des oublis. Ne pas les réintroduire sans nouvelle
discussion.

| Écarté | Raison |
|---|---|
| Polling du statut de transcription | L'app ne suit pas ce qui se passe après l'upload |
| `POST /recordings/:id/retry`, `DELETE /recordings/:id` | Conséquence du point ci-dessus |
| Liste des enregistrements dans l'app | Idem |
| Notification ou ouverture de la note après l'upload | L'utilisateur va voir dans Whiteboard quand il veut |
| File d'attente hors-ligne | Un échec est traité sur le moment, par une alerte |
| Champ `slug` | Le serveur le dérive du titre et du jour |
| Création de tags depuis l'app | On ne choisit que parmi les tags existants du workspace |
| Groupes, prompts, résumé, mail, crédits | Notions Meeting Agent, sans équivalent ici |

## 3. Parcours

### Enregistrer

1. **Clic gauche** sur l'icône → la capture démarre immédiatement, `t0` est mémorisé,
   l'icône passe en disque plein, l'ESP32 passe au rouge. La fenêtre de configuration
   s'ouvre par-dessus.
2. La fenêtre est pré-remplie : workspace, langue et visibilité = derniers utilisés
   (à défaut, le workspace par défaut des préférences), date = `t0`, titre vide et
   focus dedans, tags vides.
3. **OK** → la fenêtre se ferme, l'enregistrement continue. **Annuler** → arrêt et
   suppression du fichier. La fenêtre n'a pas de bouton de fermeture : ces deux
   boutons sont les seules sorties. **OK** reste désactivé tant que le titre est vide
   ou que la date de réunion est dans le futur, que le serveur refuserait par un 400.
4. Pendant que la fenêtre est ouverte, un clic sur l'icône la ramène au premier plan
   au lieu d'arrêter l'enregistrement.
5. **Clic gauche** → arrêt de la capture, ESP32 au noir, puis upload. L'icône passe
   dans un troisième état pendant l'envoi, et un clic y est sans effet.
6. **201** → le fichier local est supprimé, l'icône revient au repos. Rien d'autre.

Le clic droit ouvre un menu : durée écoulée si un enregistrement est en cours,
Préférences, Quitter.

### Quand l'upload échoue

Le fichier n'est jamais supprimé. Une alerte affiche le message du serveur et propose :

- **Réessayer** — relance le même upload avec les mêmes paramètres.
- **Enregistrer…** — `NSSavePanel`, dossier par défaut = préférence (`~/Downloads`),
  nom pré-rempli `<titre>.m4a`.
- **Fermer** — le fichier est déplacé dans le dossier par défaut et l'alerte indique
  où il se trouve.

## 4. Architecture

Deux cibles dans le dépôt.

### `RecorderCore` — package Swift local

Aucune dépendance à AppKit. Testable par `swift test`, sans Xcode.

| Module | Responsabilité |
|---|---|
| `WhiteboardClient` | `listWorkspaces()`, `listTags(workspaceID:)`, `upload(_:)` en async/await |
| `MultipartBody` | Écrit l'enveloppe multipart dans un fichier temporaire pour un upload streamé |
| `APIError` | Traduit les codes HTTP et le corps de réponse en message affichable |
| `Preferences` | Réglages persistés dans UserDefaults |
| `KeychainStore` | La clé API, et elle seule |
| `AudioCapture` (protocole) | `start()`, `stop() -> URL` ; implémenté par `CoreAudioCapture` et par un double de test |
| `RecordingFlow` | Machine à états, pilote l'icône et les fenêtres |
| `ESP32Display` | Écran rouge / noir, sans effet si l'IP est vide |

### `WhiteboardRecorder` — l'app

`AppDelegate`, `MenuBarController` en AppKit (le clic gauche déclenche l'action, le
clic droit ouvre le menu — comportement impossible à obtenir proprement avec
`MenuBarExtra`), et deux vues SwiftUI montées dans des `NSHostingController` : la
fenêtre de configuration et les préférences.

Projet Xcode classique (`.xcodeproj`) référençant le package local.
Cible macOS **14.4** minimum, mode langage Swift 5 : les callbacks CoreAudio se
plient mal à la concurrence stricte de Swift 6, ce n'est pas le combat du moment.

## 5. Capture audio

Un seul device agrégé, donc une seule horloge, donc aucune dérive entre les deux
sources et aucun post-traitement à l'arrêt.

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [pid de l'app])`, puis
   `AudioHardwareCreateProcessTap` — capte la sortie audio du système sans se
   réenregistrer soi-même.
2. `AudioHardwareCreateAggregateDevice`, privé, contenant le micro par défaut **et**
   le tap.
3. Un `AudioDeviceIOProc` sur l'agrégat reçoit les deux flux dans le même appel. On
   les somme en mono avec un gain par source, on écrête, on convertit via
   `AVAudioConverter`.
4. Écriture dans un `AVAudioFile` : AAC mono à 64 kb/s, conteneur `.m4a`, à la
   fréquence d'échantillonnage du device agrégé (48 kHz en général) — on évite ainsi
   un rééchantillonnage inutile. De l'ordre de 28 Mo par heure, très loin de la
   limite de 1 Gio, et sans perte utile pour de la transcription.

**Dégradation** : si le tap ne peut pas être créé ou si la permission audio est
refusée, l'agrégat est construit avec le micro seul et l'enregistrement a lieu quand
même ; la fenêtre de configuration affiche un avertissement discret indiquant que
l'audio système n'est pas capté.

`Info.plist` : `NSMicrophoneUsageDescription` et `NSAudioCaptureUsageDescription`.

Les fichiers en cours de vie sont dans
`~/Library/Application Support/WhiteboardRecorder/Recordings/<uuid>.m4a`.

## 6. API

Base : `https://whiteboard-api.kepochan.com`, header `X-API-Key: wb_…`.
`Authorization: Bearer` n'est pas lu par le serveur et donne un 401.

### `GET /workspaces`

Retourne les workspaces dont le porteur de la clé est membre. On ne garde que `id` et
`name`. Aucun scope requis. Mis en cache pour affichage immédiat, rafraîchi en tâche
de fond.

### `GET /workspaces/:id/tags`

Retourne `[{label, color, count}]`. Absent du contrat d'intégration fourni, vérifié
par appel réel le 2026-09-21. Alimente la complétion du champ tags, trié par `count`
décroissant. Mis en cache par workspace ; changer de workspace recharge la liste.

### `POST /recordings` — multipart/form-data

| Champ | Envoyé | Valeur |
|---|---|---|
| `audio` | toujours | le `.m4a`, content-type `audio/mp4` |
| `workspaceId` | toujours | UUID choisi dans la fenêtre |
| `title` | toujours | 1 à 255 caractères |
| `recordedAt` | toujours | `t0` en ISO 8601 UTC |
| `language` | toujours | `auto`, `fr` ou `en` |
| `sharingMode` | toujours | `private`, `protected`, `limited`, `editable`, `public`, `open-bar` |
| `tags` | si non vide | JSON `[{"label":…,"color":…}]`, en champ texte ; `label` et `color` repris tels quels de `GET /workspaces/:id/tags`, jamais inventés |
| `slug` | jamais | dérivé par le serveur |

L'API rejette tout champ non déclaré : ne rien ajouter d'autre. Le serveur ajoute
toujours le tag `meeting` — on ne l'envoie pas.

Le corps multipart est écrit dans un fichier temporaire et envoyé par
`URLSession.uploadTask(fromFile:)`. L'ancienne app chargeait le fichier entier en
mémoire avec `Data(contentsOf:)` : intenable pour une réunion longue.

### Erreurs

| Code | Message affiché |
|---|---|
| 400 | Le tableau `message` du corps, joint par des retours à la ligne |
| 401 | Clé API absente, fausse ou révoquée — proposer d'ouvrir les Préférences |
| 403 | Pas membre de ce workspace |
| 409 | Un slug identique existe déjà |
| 413 | Fichier trop volumineux (limite 1 Gio) |
| autre / réseau | Message système, avec le code |

## 7. Réglages

Dans le Keychain, service `com.kepochan.whiteboard-recorder` : la clé API seule.

Dans UserDefaults : workspace par défaut, URL de l'API, IP de l'ESP32, dossier de
sauvegarde, et les derniers choix (workspace, langue, visibilité). Les tags ne sont
jamais pré-remplis.

L'URL du front n'est pas un réglage : l'app n'ouvre jamais de note, donc rien ne la
lirait. À réintroduire le jour où l'app proposera d'ouvrir la note produite.

La fenêtre Préférences propose un bouton **Tester** qui appelle `GET /workspaces` et
affiche le nombre de workspaces trouvés, ou l'erreur.

Aucune clé API n'apparaît dans le code, dans les scripts ou dans un commit. Pour le
développement, la clé est lue depuis la configuration MCP existante de la machine.

## 8. Tests

TDD sur `RecorderCore`, avec un double de `HTTPSession` injecté — même intention
qu'un `URLProtocol` bouchonné (observer la requête réellement construite), sans sa
fragilité face à `upload(for:fromFile:)`.

- `MultipartBody` : octets produits, frontières, en-têtes de partie, champ `tags`
  omis quand la sélection est vide.
- `WhiteboardClient` : `recordedAt` en ISO 8601 UTC, refus d'une date future avant
  l'appel, décodage des workspaces et des tags, chaque code d'erreur vers son message.
- `Preferences` et `KeychainStore` : valeurs par défaut, persistance, suppression.
- `RecordingFlow` : transitions, y compris annulation pendant la configuration et
  échec puis réessai.

La capture audio n'est pas testable en unitaire : elle est isolée derrière le
protocole `AudioCapture`. Elle est couverte par une check-list manuelle — enregistrer
vingt secondes en parlant avec une vidéo en cours de lecture, vérifier que les deux
sources sont audibles dans le fichier produit.

## 9. Risques

1. **Process tap sous App Sandbox** — rien ne garantit que
   `AudioHardwareCreateProcessTap` fonctionne en bac à sable. Première tâche du plan :
   un programme jetable qui tente la capture, sandbox activé. En cas d'échec, on
   désactive le sandbox : sans distribution App Store, il ne coûte rien.
2. **Scope de `GET /workspaces/:id/tags`** — l'endpoint peut exiger un scope de
   lecture des notes, alors que la clé du recorder ne porte que `recordings:read` et
   `recordings:write`. Le test du 2026-09-21 a utilisé une clé plus large et ne
   tranche pas. À vérifier avec une vraie clé recorder ; en cas de 403, ajouter le
   scope à la clé, ou masquer le champ tags.
3. **Écriture AAC directe par `AVAudioFile`** — si le format compressé pose problème
   à l'écriture, replier sur un fichier non compressé puis un export `.m4a` à l'arrêt.

## 10. Nommage et distribution

- Dépôt : `~/work/whiteboard-recorder`, distant `kepochan/whiteboard-recorder`.
- Bundle : `com.kepochan.whiteboard-recorder`, nom affiché « Whiteboard Recorder ».
- `run.sh` compile en debug et lance ; `build-release.sh` compile en release et
  produit le `.app`. Ni l'un ni l'autre ne contient de clé, contrairement aux
  scripts de l'ancienne app.
- Le `.app` zippé est committé dans le dépôt pour être téléchargeable, comme
  aujourd'hui.
