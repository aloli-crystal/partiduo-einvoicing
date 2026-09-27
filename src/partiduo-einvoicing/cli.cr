# SPDX-License-Identifier: AGPL-3.0-or-later

# Migrations de l'extension, requises par la ligne de commande Marten de la
# distribution (`require "partiduo-einvoicing/cli"`), comme `partiduo/cli`
# pour le cœur.
require "marten/cli"

require "../einvoicing/migrations/**"
