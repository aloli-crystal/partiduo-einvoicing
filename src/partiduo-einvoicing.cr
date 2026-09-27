# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-einvoicing` : le métier de l'extension
# EINV (manifeste, modèles, connecteurs de plateforme agréée, formats,
# abonnements, contrat `Einvoicing::Api`), sans interface. L'interface Bulma
# est dans `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-einvoicing/ui/bulma"`.
#
# La distribution ajoute ensuite `Einvoicing::INSTALLED_APPS` à ses
# applications Marten (après celles de `partiduo-document`), et
# `require "partiduo-einvoicing/cli"` à sa ligne de commande (migrations).
require "partiduo"
require "partiduo-document"

require "./einvoicing/app"
