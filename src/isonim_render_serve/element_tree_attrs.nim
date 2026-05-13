## isonim_render_serve/element_tree_attrs.nim — shared attribute names
## consumed by every element-tree manifest builder.
##
## RS-M11 / RS-M11b: the TUI, GPUI, and Freya streaming adapters all
## read the same two ``data-*`` attributes off their renderer's
## headless node tree to decide (a) which nodes surface in the
## element-tree manifest at all and (b) what kind label each entry
## carries.
##
## Lifting the constants out of any one adapter means demos can also
## consume them from a single import — see
## ``isonim-examples/task_app/core/component_paths.nim`` for the demo-
## level taxonomy that builds on top of these.
##
## Adding a new adapter (Cocoa, Android, …): import this module and
## walk the renderer-specific tree, reading these two attributes via
## the renderer's ``getAttribute`` accessor.

const ComponentPathAttr* = "data-component-path"
  ## Attribute name carrying the canonical component path string
  ## (e.g. ``task_app/views/TaskRow#7``). Manifest filter: a node
  ## with a non-empty value here surfaces in the manifest; nodes
  ## without the attribute are skipped.

const ElementKindAttr* = "data-component-kind"
  ## Attribute name carrying the optional UX kind label
  ## (e.g. ``row``, ``input``, ``filter-bar``). When absent, the
  ## entry's ``kind`` field is the empty string (the manifest codec
  ## handles ``""`` correctly per RS-M11's schema lock).
