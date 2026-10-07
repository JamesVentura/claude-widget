# Claude Widget

Petite fenêtre flottante pour macOS qui montre où en sont tes discussions
Claude Code, sans avoir à ouvrir l'application.

Au repos, une ligne par discussion : une pastille d'état, le titre, et une flèche
orange qui ouvre la discussion dans Claude. Le détail n'apparaît qu'au survol.

```
🦀 Claude   Slay the day, pas ton énergie.              ^  ✕
────────────────────────────────────────────────────────────
● Refonte profil LinkedIn                             [ → ]
● Brioche recette en cups/ml                          [ → ]
● Comparaison école française IEG                     [ → ]
```

## Les trois états

| Pastille | État | Signification |
|---|---|---|
| 🟢 vert (clignote) | **en cours** | Claude travaille en ce moment |
| 🟠 orange | **à toi** | Claude a répondu et attend ta réponse (moins de 48 h) |
| ⚪️ gris | **en pause** | Discussion inactive |

Les discussions « en cours » sont en haut, puis celles qui t'attendent, puis le
reste. Rafraîchissement toutes les 4 secondes.

## Installation

Il faut les outils de développement en ligne de commande d'Apple (`swiftc`), que
macOS propose d'installer tout seul la première fois :

```
xcode-select --install
```

Ensuite :

```
git clone <url-du-depot>
cd claude-widget
./build.sh
open "Claude Widget.app"
```

Aucune autre dépendance : ni Node, ni Electron, ni Xcode complet.

## Utilisation

- **Afficher / rouvrir** : double-clic sur `Claude Widget.app`. Pour l'avoir sous
  la main, fais-en un alias (clic droit → *Créer un alias*) et pose-le où tu veux.
- **Déplacer** : glisse la fenêtre, la position est mémorisée.
- **Replier / déplier** : le chevron `^` en haut à droite.
- **Fermer** : la croix `✕`.
- **Voir le détail** : survole une ligne — dossier, état, date, dernier message de
  Claude et ta dernière demande. La fenêtre s'agrandit le temps du survol.
- **Ouvrir une discussion** : le bouton orange `→`.
- **Lancement au démarrage** : double-clic sur `Démarrage automatique.command`
  (une seule fois), ou *Réglages Système → Général → Ouverture*.

## D'où viennent les données

Deux sources, toutes deux locales. Rien ne sort de la machine : aucun appel
réseau, aucune clé d'API, aucun token consommé.

1. **Le registre de l'app** —
   `~/Library/Application Support/Claude/claude-code-sessions/<compte>/<orga>/local_*.json`
   Titre officiel, dossier de travail, session archivée ou non, et l'identifiant
   `sessionId` qui sert au bouton orange. Son champ `cliSessionId` pointe vers le
   transcript. Ces fiches pèsent ~350 Ko : elles ne sont relues que si elles ont
   changé.

2. **Le transcript** — `~/.claude/projects/<projet>/<cliSessionId>.jsonl`
   L'avancement. Seule la fin du fichier est lue, certains font 40 Mo.

Le bouton orange ouvre `claude://claude.ai/epitaxy/<sessionId>`, le schéma d'URL
que l'application Claude déclare elle-même.

Un rafraîchissement complet prend environ 0,2 s.

### Portée : Claude Code uniquement

Les sessions **Cowork** et les **conversations classiques** n'apparaissent pas, et
ne peuvent pas apparaître : elles vivent sur les serveurs d'Anthropic, l'app ne
les stocke pas sur le disque. Les inclure imposerait d'appeler l'API avec les
jetons d'authentification de l'utilisateur — hors de question pour un widget.

Claude Code, lui, tourne en local : d'où le registre et les transcripts.

## Le message du matin

À droite de « Claude », une phrase change chaque jour. Les 100 messages sont dans
[`src/quotes.swift`](src/quotes.swift) — ajoute, supprime, réécris : la rotation
s'adapte au nombre de lignes.

Le message est calculé à partir de la date locale, pas tiré au sort. Il reste le
même toute la journée, bascule à minuit, et les 100 défilent sans répétition.

## La mascotte

Le personnage orange est dessiné en pixel art dans `src/main.swift`
(`struct Mascot`), et l'icône de l'app est générée à partir du même dessin par
[`resources/icon.swift`](resources/icon.swift).

Pour utiliser une autre image : pose un `mascot.png` à côté de `Claude Widget.app`.
Il est pris en compte sans recompiler, et affiché sans lissage.

## Réglages

En haut de `enum Scan` dans [`src/main.swift`](src/main.swift) :

```swift
static let maxAgeDays: Double = 14     // fenêtre d'affichage (jours)
static let maxRows = 14                // nombre max de lignes
```

Puis `./build.sh`, et relance l'app.

## Structure

```
src/main.swift        lecture des sessions, interface, fenêtre
src/quotes.swift      les 100 messages du matin
resources/Info.plist  description du bundle (LSUIElement : pas d'icône au Dock)
resources/AppIcon.icns
resources/icon.swift  générateur d'icône
build.sh              assemble Claude Widget.app
```

`Claude Widget.app` est un produit de compilation, il n'est pas versionné.
