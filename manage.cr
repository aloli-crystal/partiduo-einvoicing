# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de l'extension, composée avec le cœur, DOCUMENT
# et l'interface comme dans une distribution :
# `crystal run manage.cr -- <commande>` (`genmigrations einvoicing`, `migrate`…).
require "partiduo-ui-bulma/partiduo_ui"
require "./src/partiduo-einvoicing"
require "partiduo-document/ui/bulma"
require "./ui/bulma/bulma"
require "./config/settings/base"
require "./config/settings/**"
require "partiduo/cli"
require "partiduo-document/cli"
require "./src/partiduo-einvoicing/cli"

Marten.setup
Marten::CLI.run
