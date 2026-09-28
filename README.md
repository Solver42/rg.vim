# rg.vim

Requires Vim 9+ and ripgrep installed.

## Use

    :Rg            open the picker
    :Rg {text}     open with an initial query

| Key                       | Action                         |
|---------------------------|--------------------------------|
| type                      | filter live                    |
| `<BS>` `<C-h>`            | delete last character          |
| `<C-u>`                   | clear the query                |
| `<C-n>` `<Down>` `<C-j>`  | next file                      |
| `<C-p>` `<Up>` `<C-k>`    | previous file                  |
| `<C-d>` `<C-f>` / `<C-b>` | scroll preview down / up       |
| `<Enter>`                 | open file at its first match   |
| `<Esc>` `<C-c>`           | close                          |

Suggested mapping: `nnoremap <leader>g :Rg<CR>`

## Options

    g:rg_context      lines shown before/after each match   (default 2)
    g:rg_max_files    max files listed                      (default 500)
    g:rg_max_matches  max matches previewed per file        (default 30)

## Notes

- Search is a fixed string (not regex), smart-case: case-insensitive unless
  the query contains an uppercase letter.
- With an empty query it lists every file (respecting `.gitignore` via `rg`).
