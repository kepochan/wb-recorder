# whiteboard-recorder — upload repris par morceaux

Date : 2026-10-15
Statut : implémenté
Source : note Whiteboard `whiteboard-recorder-resumable-upload-prompt` (contrat
d'API, ticket WB #1110) et réponses de l'agent backend aux questions Q1–Q8 de
cette note.

## 1. Objectif

Un enregistrement envoyé depuis une liaison lente doit arriver, même s'il faut
plusieurs minutes, plusieurs coupures ou un redémarrage de l'app. Aujourd'hui,
l'app l'envoie en un seul `POST /recordings`. Traefik coupe toute requête au
bout de 60 s (`readTimeout`) : au-delà de ~60 s d'envoi, l'envoi échoue, et
chaque nouvelle tentative repart de zéro.

Cas observé le 2026-10-14 (Japon, Wi-Fi) : deux envois coupés en 502 à 60,4 s,
après seulement 2,3 Mo partis sur 18,6 Mo (~38 Ko/s). Le backend n'a jamais reçu
de fichier complet.

## 2. Décisions

Prises avec l'agent backend dans la note (Q1–Q8). Elles remplacent les lignes
correspondantes de la spec du 2026-09-21.

| # | Décision |
|---|---|
| Q1 | `complete` répond en quelques millisecondes (transcription en tâche de fond). Un 502 ou un timeout sur `complete` reste un échec transitoire ordinaire : `complete` est idempotent. |
| Q2 | Pas de polling de la transcription. L'envoi est terminé au `201` de `complete`, et la copie locale est supprimée à ce moment-là, comme aujourd'hui au 2xx. |
| Q3 | Un seul chemin : par morceaux, pour tous les fichiers. `POST /recordings` n'est plus appelé. |
| Q4 | Reprise automatique au retour du réseau (`NWPathMonitor`), seulement depuis l'état pause, un essai par retour du réseau. « Resume upload » reste disponible. |
| Q5 | Les envois sont persistés et repris automatiquement au lancement, annoncés par une notification. Un `404` après un `complete` envoyé n'est **jamais** renvoyé automatiquement : il est signalé. |
| Q6 | L'envoi passe en arrière-plan. Un nouvel enregistrement peut démarrer pendant un envoi en cours ou en pause. Un seul envoi à la fois ; les suivants attendent dans une file qui survit à un quit. |
| Q7 | Barre de progression déterminée (`offset / size`, Mo envoyés / Mo total) ; « Resume upload » en pause ; fenêtre fermable pendant l'envoi ; état de l'envoi dans le menu clic droit. Textes en anglais. |
| Q8 | L'app n'envoie toujours pas de slug. Un `409` de slug à `complete` → rappel automatique avec `{ "slug": null }`. |

Ce que ça change dans la spec d'origine : la ligne « File d'attente hors-ligne —
écarté » tombe (Q6). « Un clic sur l'icône est sans effet pendant l'envoi » tombe
aussi : le clic démarre un nouvel enregistrement. Le reste du hors-périmètre
(polling, retry/delete serveur, champ slug, notification ou ouverture de la note
après l'envoi) est inchangé.

## 3. Composants

Le cœur reste dans `RecorderCore`, testable sans réseau ni AppKit. L'app ne fait
que l'orchestration et l'affichage.

### 3.1 `WhiteboardClient` — les quatre appels (RecorderCore)

Nouvelles méthodes, sur le modèle de `get`/`check` existants :

- `startUpload(_ request: UploadStart) -> UploadSession` — `POST /recordings/uploads`,
  corps JSON : métadonnées (`tags` en vrai tableau), `size`, `mimeType:
  "audio/mp4"`, `filename`. Renvoie `uploadId`, `offset`, `size`, `chunkSize`.
- `putChunk(uploadId:offset:data:) -> ChunkResult` — `PUT
  /recordings/uploads/:id?offset=N`, `application/octet-stream`. Résultats :
  `.advanced(offset)` (200), `.offsetMismatch(offset)` (409 avec `offset`),
  `.alreadyCompleted` (409 « Upload already completed »).
- `uploadStatus(uploadId:) -> UploadStatus` — `GET`, renvoie `offset`, `size`,
  `recordingId?`.
- `completeUpload(uploadId:defaultSlug:) -> UploadedRecording?` — `POST
  …/complete`, corps `{}` ou `{ "slug": null }`. Même règle qu'aujourd'hui : un
  2xx dont le corps ne se décode pas reste un succès.

Chaque requête a un timeout de 60 s (`timeoutInterval`). `APIError` gagne la
lecture du champ `offset` dans un corps de 409 ; un 409 sans `offset` reste le
`.conflict` actuel (titre et date déjà pris, à `start`).

`upload(_:)` et `MultipartBody` sont supprimés (Q3), avec leurs tests.

### 3.2 `PendingUpload` et `PendingUploadStore` (RecorderCore)

Un envoi en attente, tel qu'il survit à un quit :

```swift
struct PendingUpload: Codable, Equatable {
    let id: UUID                 // identifiant local
    let fileName: String         // dans RecordingStorage.directory
    let size: Int64              // mesuré à la mise en file, après finalisation
    let configuration: RecordingConfiguration  // devient Codable
    var uploadId: String?        // nil tant que start n'a pas répondu
    var completeSent: Bool       // vrai dès que complete est parti
}
```

`fileName` est relatif au dossier de travail, pas un chemin absolu : le chemin du
conteneur sandbox n'a pas à être figé dans le fichier.

`PendingUploadStore` lit et écrit la file entière (ordre = ordre d'envoi) dans
`Application Support/WhiteboardRecorder/pending-uploads.json`, en écriture
atomique. Il est mis à jour à chaque changement d'état qui compte pour une
reprise : mise en file, `uploadId` reçu, `completeSent`, retrait. L'offset n'est
**pas** persisté : le serveur en est la source de vérité (`GET`).

### 3.3 `ChunkedUploader` (RecorderCore)

Envoie **un** `PendingUpload` jusqu'au bout, ou s'arrête en disant pourquoi.
Dépendances injectées : le client, une fonction `sleep` (pour les tests), un
rappel de progression `(sent, total)`, un rappel `persist(PendingUpload)`.

1. Pas d'`uploadId` → `start`, puis `persist`. Sinon → `GET` pour connaître
   l'offset serveur. Si `recordingId` est présent → étape 4.
2. Boucle : lire `[offset, offset + chunkSize)` depuis le fichier par
   `FileHandle` (jamais tout le fichier en mémoire), `PUT`, avancer.
   `.offsetMismatch(n)` → recalage sur `n`, sans compter d'échec.
   `.alreadyCompleted` → étape 4.
3. Échec **transitoire** (erreur réseau `URLError`, timeout, 5xx, réponse
   illisible) → attente 1 s, 2 s, 4 s ; avant chaque reprise, `GET` l'offset et
   repartir de là. Le compteur d'échecs consécutifs revient à zéro à chaque
   succès. Au 4ᵉ échec consécutif → fin `.paused(message)`. `start`, `GET` et
   `complete` suivent la même règle.
4. `persist(completeSent = true)`, puis `complete`. `409` « Upload is not
   complete » → retour à l'étape 2 à l'offset donné. `409` de slug → `complete`
   avec `{ "slug": null }`. `201` → fin `.completed(UploadedRecording?)`.
5. `404` (session inconnue ou purgée) :
   - `completeSent == false` → nouvelle session depuis zéro (`uploadId = nil`,
     étape 1), sans compter d'échec ;
   - `completeSent == true` → fin `.maybeAlreadyUploaded`. Jamais de renvoi
     automatique : une nouvelle session créerait une seconde note.
6. Échec **définitif** (400, 401, 403, 409 sans `offset` à `start`, 413, fichier
   local introuvable) → fin `.failed(APIError)`.

Il est annulable (`Task` coopérative) : un quit ou une pause demandée arrête la
boucle entre deux appels, sans rien corrompre, puisque le serveur n'ajoute un
morceau qu'une fois reçu en entier.

### 3.4 `UploadCoordinator` (app, `@MainActor`, `ObservableObject`)

Possède la file et fait tourner un `ChunkedUploader` à la fois.

État publié, lu par la fenêtre et le menu :

```swift
enum UploadActivity {
    case idle
    case uploading(id: UUID, title: String, sent: Int64, total: Int64)
    case paused(id: UUID, title: String, message: String)
}
var queuedCount: Int   // envois en attente derrière l'actuel
```

- `enqueue(fileURL:configuration:)` : mesure la taille, ajoute à la file, persiste,
  démarre si rien ne tourne.
- `resume()` : depuis `.paused`, relance l'envoi en tête (« Resume upload »).
- `NWPathMonitor` : passage à `satisfied` pendant `.paused` → un `resume()`.
  Un nouvel échec reste en pause jusqu'au prochain retour du réseau ou à un
  clic.
- Au lancement : charge la file ; retire (avec une alerte) les entrées dont le
  fichier a disparu ; si la file n'est pas vide, notification « Resuming upload
  of “<title>” » puis démarrage.
- Fins de `ChunkedUploader` :
  - `.completed` → supprime le fichier, retire l'entrée, passe au suivant ; si
    la fenêtre de cet envoi est ouverte, elle affiche « Sent ».
  - `.paused` → état `.paused`, notification « Upload paused ». La file reste
    bloquée sur cet envoi (ordre conservé).
  - `.failed` ou `.maybeAlreadyUploaded` → retire l'entrée de la file et passe
    le fichier à la gestion d'échec actuelle (§ 3.6), puis passe au suivant.

Les notifications utilisent `UNUserNotificationCenter`. L'autorisation est
demandée à la première mise en file, pas au lancement. Si elle est refusée, rien
d'autre ne change : la fenêtre et le menu montrent toujours l'état.

### 3.5 `RecordingFlow` et `MenuBarController`

L'envoi sort de la machine à états de l'enregistrement :

- `(.configuring, .configurationConfirmed)` → état `.idle`, effets
  `.enqueueUpload(configuration)` et icône. Le fichier est confié au
  coordinateur ; `currentFileURL` est remis à nil.
- Les états `.uploading` et `.failed(configuration?, …)` et les événements
  `uploadSucceeded`, `uploadFailed`, `retryRequested` disparaissent du flux.
  Reste `.failed(nil, …)` pour un échec de capture, inchangé.
- Icône : enregistrement en cours → disque plein ; sinon, un envoi en cours ou
  en pause → icône d'envoi ; sinon → repos. Un clic gauche hors enregistrement
  démarre un nouvel enregistrement, même pendant un envoi.

### 3.6 Échecs définitifs

L'alerte actuelle (`FailureAlert`) est réutilisée, avec un fichier et une
configuration fournis par le coordinateur au lieu de `flow.state` :

- **Retry** → remet l'envoi en tête de file (en gardant l'`uploadId` s'il y en a
  un).
- **Open Preferences…** (clé refusée) → puis l'alerte revient, comme aujourd'hui.
- **Save…** / **Close** → comme aujourd'hui (enregistrer sous, ou déplacer dans
  le dossier de sauvegarde).

Pour `.maybeAlreadyUploaded`, le message devient : « This recording may already
be on Whiteboard: the upload was finishing when it was interrupted. Check
before uploading it again. » Le bouton **Retry** s'appelle alors « Upload
again » (nouvelle session depuis zéro).

Une alerte modale peut s'ouvrir pendant qu'un nouvel enregistrement tourne.
Elle ne l'interrompt pas (la capture tourne hors du fil principal), mais le clic
d'arrêt attend qu'elle soit fermée. Accepté pour cette étape.

### 3.7 Quit et lancement (`RecordingRescue`)

- **Quit pendant un envoi** : l'envoi est annulé et reste dans la file
  persistée ; le fichier reste dans le dossier de travail. Pas d'alerte : il
  reprendra au prochain lancement. L'enregistrement en cours ou la fenêtre de
  configuration ouverte sont traités comme aujourd'hui (capture finalisée,
  fichier mis à l'abri dans le dossier de sauvegarde).
- **Balayage au lancement** : `sweepStrandedRecordings` ignore les fichiers
  référencés par la file. Il tourne avant la reprise de la file.

### 3.8 Fenêtre de configuration

La phase `.uploading` de la fenêtre lit l'`UploadActivity` du coordinateur pour
**son** envoi :

- en cours : `ProgressView(value:)` + « 12.4 MB of 18.6 MB » ;
- en attente derrière un autre envoi : « Waiting for the previous upload to
  finish… » ;
- en pause : le message, et **Resume upload** ;
- dans tous les cas, un bouton **Close** : « The upload continues in the
  background. »

Un nouvel enregistrement qui ouvre une nouvelle fenêtre de configuration ferme
l'ancienne, comme aujourd'hui ; l'envoi n'en dépend pas.

### 3.9 Menu clic droit

Une ligne d'état, sans action, au-dessus de Preferences (même mécanisme que la
ligne de durée) : « Uploading “<title>” — 42 % », « Upload paused — <title> »
avec un élément **Resume upload**, et « + 2 waiting » s'il y a une file.

## 4. Tests

RecorderCore, avec un `FakeSession` étendu pour répondre selon une liste de
réponses scriptées (ou d'erreurs) :

- client : corps JSON de `start` (`tags` en tableau, `size`, `mimeType`,
  `filename`, aucun champ en trop), en-têtes et corps du `PUT`, lecture des 409
  avec `offset`, corps de `complete` ;
- uploader : envoi nominal en plusieurs morceaux ; recalage sur 409 ; reprise
  après erreur réseau au bon offset (via `GET`) ; pause au 4ᵉ échec consécutif
  et remise à zéro du compteur après un succès ; `404` avant et après
  `completeSent` ; `.alreadyCompleted` et `recordingId` présent → `complete` ;
  409 de slug → `{ "slug": null }` ; échec définitif ; aucune lecture du fichier
  entier en mémoire (taille du `Data` envoyé ≤ `chunkSize`) ;
- store : aller-retour JSON, ordre conservé, fichier absent → file vide ;
- flux : `configurationConfirmed` → `.idle` + `.enqueueUpload`.

Vérification réelle avant de dire que c'est fini (demandée dans la note) : un
fichier de plusieurs dizaines de Mo, avec une coupure Wi-Fi ou Network Link
Conditioner en cours d'envoi, qui reprend à l'offset serveur et aboutit à une
note transcrite ; puis un quit en plein envoi suivi d'une reprise au
relancement.
