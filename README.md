# Advanced Search On Mail

Application macOS de barre de menu qui offre une **recherche avancée et rapide dans Apple Mail** : objet, corps, expéditeur, destinataires, dates, pièces jointes et boîte aux lettres.

Un double-clic sur un résultat ouvre le message dans Mail ; la fenêtre de recherche reste ouverte pour poursuivre la recherche.

## Fonctionnalités

- Recherche dans l'**objet**, le **corps**, l'**expéditeur** et les **destinataires** (au choix).
- Plusieurs mots : chacun doit être trouvé (ET). Insensible à la casse et aux accents.
- Filtres : **date de début / de fin**, **avec / sans pièce jointe**, **boîte aux lettres** (ou « Boîte active de Mail »).
- Résultats instantanés dans un tableau (date, expéditeur, objet, dossier), les 1000 plus récents.
- Fenêtre toujours au premier plan, pour rester visible quand Mail s'ouvre.

## Prérequis

- macOS 26 ou plus récent (cible de déploiement actuelle du projet).
- Apple Mail avec au moins un compte configuré.
- Xcode pour compiler depuis les sources.

## Installation

1. Ouvrez `Advanced Search On Mail.xcodeproj` dans Xcode.
2. Choisissez le schéma **Advanced Search On Mail** et la destination **My Mac**.
3. Lancez avec **⌘R**, ou faites Product › Archive pour obtenir l'app.

> Ne lancez pas le schéma « Advanced Search » : c'est l'extension MailKit, qui n'est pas nécessaire pour la recherche.

## Autorisations (première utilisation)

| Autorisation | Pourquoi | Où l'activer |
|---|---|---|
| **Accès complet au disque** | Lire la base de Mail et les fichiers `.emlx` | Réglages Système › Confidentialité et sécurité › Accès complet au disque |
| **Automatisation (Mail)** | Bouton « Boîte active de Mail » | Réglages Système › Confidentialité et sécurité › Automatisation |

Après avoir accordé l'accès complet au disque, relancez l'application.

## Lancer une recherche

1. Lancez l'app : la fenêtre s'ouvre, et une icône loupe apparaît dans la barre de menu.
2. Pour rouvrir la fenêtre plus tard : cliquez sur l'icône puis **Rechercher dans Mail…** (⇧⌘F).
3. Saisissez vos mots-clés ; la recherche démarre automatiquement (ou appuyez sur Entrée).
4. Cochez où chercher (Objet, Corps, Expéditeur, Destinataires).
5. Ajoutez des filtres : dates, pièce jointe, boîte.
6. **Double-cliquez** sur un résultat pour l'ouvrir dans Mail.

## Fonctionnement et performances

- Les métadonnées (objet, expéditeur, dates, pièces jointes, boîtes) sont lues directement dans la base `Envelope Index` de Mail, en lecture seule.
- Le contenu des mails est indexé dans un index plein texte SQLite (FTS5) stocké dans `~/Library/Application Support/AdvancedSearchOnMail/index.sqlite`.
- La **première indexation** peut durer quelques minutes (progression affichée en bas de la fenêtre), les mails récents d'abord. La recherche dans le corps est complète une fois l'indexation terminée. L'index se met ensuite à jour toutes les 3 minutes.
- Aucune donnée ne quitte votre Mac.

## Dépannage

- **Aucun résultat / bandeau orange** : vérifiez l'accès complet au disque, puis relancez l'app.
- **Icône absente de la barre de menu** : elle peut être masquée par l'encoche ou une barre trop remplie ; la fenêtre s'ouvre de toute façon au lancement.
- **« Boîte active de Mail » échoue** : sélectionnez une boîte précise (pas une boîte unifiée) dans Mail et autorisez l'automatisation.
- **Un message ne s'ouvre pas** : le compte est peut-être inactif ou le message non téléchargé ; activez le compte dans Mail.
- **Réinitialiser l'index** : quittez l'app et supprimez le dossier `~/Library/Application Support/AdvancedSearchOnMail`.

## Limites

- L'app ne modifie pas la recherche intégrée de Mail et ne peut pas ajouter de bouton à sa barre d'outils (MailKit ne le permet pas) ; elle fonctionne en application séparée.
- Elle s'appuie sur la structure interne de la base de Mail, qui peut changer selon les versions de macOS.
- L'app n'est pas sandboxée (nécessaire pour lire les données de Mail) : elle ne peut donc pas être distribuée sur le Mac App Store.

## Structure du projet

- `Advanced Search On Mail/` : l'application (SwiftUI) — interface, accès à la base de Mail, indexation.
- `Advanced Search/` : extension MailKit (modèle de base, non utilisée par la recherche).

## Licence

À définir.
