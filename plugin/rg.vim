vim9script

if exists('g:loaded_rg_vim')
  finish
endif
g:loaded_rg_vim = 1

command! -nargs=? -bar Rg call ripgrep#Open(<q-args>)

# Let a lowercase :rg work too.
cnoreabbrev <expr> rg getcmdtype() ==# ':' && getcmdline() ==# 'rg' ? 'Rg' : 'rg'
