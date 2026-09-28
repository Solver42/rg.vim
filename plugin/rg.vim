vim9script

# rg.vim - full-screen live grep picker.
#
#   :Rg          open the picker in the current directory
#   :Rg {text}   open it with an initial query
#
# Left pane : files that contain a match (with match counts)
# Right pane: matches in the highlighted file, with context lines
#
# Keys:  type to filter   <BS>/<C-h> delete   <C-u> clear query
#        <C-n>/<Down>/<C-j> next file   <C-p>/<Up>/<C-k> previous file
#        <C-d>/<C-f> scroll preview down   <C-b> scroll preview up
#        <CR> open file at first match   <Esc>/<C-c> close

if exists('g:loaded_rg_vim')
  finish
endif
g:loaded_rg_vim = 1

const CONTEXT = get(g:, 'rg_context', 2)       # lines shown before/after a match
const MAX_FILES = get(g:, 'rg_max_files', 500) # cap on listed files
const MAX_MATCHES = get(g:, 'rg_max_matches', 30) # cap on matches shown per file

# ---------------------------------------------------------------------------
# State (one picker at a time)
# ---------------------------------------------------------------------------
var query = ''
var results: list<dict<any>> = []   # [{file: str, count: number, lines: list<number>}]
var selected = 0
var job: job
var out_lines: list<string> = []
var files_win = 0
var preview_win = 0
var use_rg = executable('rg')
var all_files: list<string> = []    # used when the query is empty

# ---------------------------------------------------------------------------
# Highlight groups
# ---------------------------------------------------------------------------
def DefineHighlights()
  highlight default link RgSelected PmenuSel
  highlight default link RgCount Comment
  highlight default link RgMatch Search
  highlight default link RgLineNr LineNr
  highlight default link RgSep Comment
  highlight default link RgPrompt Title
enddef

# ---------------------------------------------------------------------------
# Searching
# ---------------------------------------------------------------------------

# Command that lists "file:line:text" for every matching line, or the file
# list when the query is empty.
def SearchCmd(): list<string>
  if query == ''
    return use_rg
      ? ['rg', '--files', '--color=never']
      : ['sh', '-c', "find . -type f -not -path '*/.git/*' | sed 's|^\\./||'"]
  endif
  return use_rg
    ? ['rg', '--line-number', '--no-heading', '--with-filename', '--color=never',
       '--smart-case', '--fixed-strings', '--max-columns=500', '--', query]
    : ['grep', '-rIn', '--exclude-dir=.git', '-i', '-F', '--', query, '.']
enddef

def StartSearch()
  if job_status(job) ==# 'run'
    job_stop(job)
  endif
  out_lines = []
  job = job_start(SearchCmd(), {
    out_cb: (_, line) => add(out_lines, line),
    exit_cb: (_, _) => Finished(),
    out_mode: 'nl',
    err_io: 'null',
  })
enddef

# Group grep output by file. Runs when the job exits.
def Finished()
  var by_file: dict<dict<any>> = {}
  var order: list<string> = []
  for l in out_lines
    if query == ''
      var f = substitute(l, '^\./', '', '')
      by_file[f] = {file: f, count: 0, lines: []}
      add(order, f)
    else
      var m = matchlist(l, '^\(.\{-}\):\(\d\+\):')
      if empty(m)
        continue
      endif
      var f = substitute(m[1], '^\./', '', '')
      if !has_key(by_file, f)
        by_file[f] = {file: f, count: 0, lines: []}
        add(order, f)
      endif
      by_file[f].count += 1
      add(by_file[f].lines, str2nr(m[2]))
    endif
  endfor
  sort(order)
  results = mapnew(order[: MAX_FILES - 1], (_, f) => by_file[f])
  selected = min([selected, max([len(results) - 1, 0])])
  Render()
enddef

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def Render()
  if files_win == 0
    return
  endif
  RenderFiles()
  RenderPreview()
enddef

def RenderFiles()
  var width = popup_getpos(files_win).core_width
  var text: list<any> = []
  for i in range(len(results))
    var r = results[i]
    var count = query == '' ? '' : ' ' .. r.count
    var name = r.file
    var room = width - strwidth(count) - 1
    if strwidth(name) > room
      name = '…' .. strcharpart(name, strchars(name) - room + 1)
    endif
    var pad = repeat(' ', max([room - strwidth(name), 0]))
    var line = name .. pad .. count
    var props: list<dict<any>> = []
    if i == selected
      props = [{col: 1, length: len(line), type: 'RgSelected'}]
    elseif count != ''
      props = [{col: len(name .. pad) + 1, length: len(count), type: 'RgCount'}]
    endif
    add(text, {text: line, props: props})
  endfor
  if empty(text)
    text = [{text: ' no matches', props: [{col: 1, length: 11, type: 'RgCount'}]}]
  endif
  popup_settext(files_win, text)
  # Keep the selection scrolled into view.
  win_execute(files_win, 'normal! ' .. (selected + 1) .. 'Gzz')
  popup_setoptions(files_win, {title: ' rg > ' .. query .. '█ (' .. len(results) .. ' files) '})
enddef

def RenderPreview()
  if empty(results)
    popup_settext(preview_win, '')
    return
  endif
  var r = results[selected]
  var path = r.file
  if !filereadable(path)
    popup_settext(preview_win, '')
    return
  endif

  var file_lines = readfile(path, '', 5000)
  var total = len(file_lines)
  var text: list<any> = []
  var digits = len(string(total))

  # Plain file preview when there's no query.
  var hits = query == '' ? [1] : r.lines[: MAX_MATCHES - 1]

  # Build merged ranges of [first, last] line numbers to display.
  var ranges: list<list<number>> = []
  for h in hits
    var lo = max([h - CONTEXT, 1])
    var hi = min([h + CONTEXT, total])
    if query == ''
      hi = min([total, 200])
    endif
    if !empty(ranges) && lo <= ranges[-1][1] + 1
      ranges[-1][1] = max([ranges[-1][1], hi])
    else
      add(ranges, [lo, hi])
    endif
  endfor

  var ql = len(query)
  for idx in range(len(ranges))
    if idx > 0
      add(text, {text: repeat('─', 20), props: [{col: 1, length: 60, type: 'RgSep'}]})
    endif
    for n in range(ranges[idx][0], ranges[idx][1])
      var prefix = printf('%' .. digits .. 'd ', n)
      var line = substitute(file_lines[n - 1], '\t', '  ', 'g')
      var props = [{col: 1, length: len(prefix), type: 'RgLineNr'}]
      if query != ''
        var start = 0
        # smart-case: only case-sensitive when the query has uppercase.
        var hay = query =~# '[A-Z]' ? line : tolower(line)
        var needle = query =~# '[A-Z]' ? query : tolower(query)
        while true
          var pos = stridx(hay, needle, start)
          if pos < 0
            break
          endif
          add(props, {col: len(prefix) + pos + 1, length: ql, type: 'RgMatch'})
          start = pos + max([ql, 1])
        endwhile
      endif
      add(text, {text: prefix .. line, props: props})
    endfor
  endfor

  popup_settext(preview_win, text)
  popup_setoptions(preview_win, {title: ' ' .. path .. ' '})
  win_execute(preview_win, 'normal! gg')
enddef

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
def Move(delta: number)
  if empty(results)
    return
  endif
  selected = (selected + delta + len(results)) % len(results)
  Render()
enddef

def OpenSelected()
  if empty(results)
    return
  endif
  var r = results[selected]
  var lnum = empty(r.lines) ? 1 : r.lines[0]
  Close()
  execute 'edit ' .. fnameescape(r.file)
  cursor(lnum, 1)
  normal! zz
enddef

def Close()
  var wins = [files_win, preview_win]
  files_win = 0
  preview_win = 0
  for w in wins
    if w != 0
      popup_close(w)
    endif
  endfor
  if job_status(job) ==# 'run'
    job_stop(job)
  endif
enddef

def Filter(winid: number, key: string): bool
  if key == "\<Esc>" || key == "\<C-c>"
    Close()
  elseif key == "\<CR>"
    OpenSelected()
  elseif key == "\<C-n>" || key == "\<Down>" || key == "\<C-j>"
    Move(1)
  elseif key == "\<C-p>" || key == "\<Up>" || key == "\<C-k>"
    Move(-1)
  elseif key == "\<C-d>" || key == "\<C-f>"
    win_execute(preview_win, "normal! \<C-d>")
  elseif key == "\<C-b>"
    win_execute(preview_win, "normal! \<C-u>")
  elseif key == "\<BS>" || key == "\<C-h>" || key == "\<Del>"
    query = strcharpart(query, 0, max([strchars(query) - 1, 0]))
    selected = 0
    StartSearch()
  elseif key == "\<C-u>"
    query = ''
    selected = 0
    StartSearch()
  elseif strchars(key) == 1 && char2nr(key) >= 32
    query ..= key
    selected = 0
    StartSearch()
  endif
  return true  # swallow every key while the picker is open
enddef

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def Open(initial: string)
  Close()
  DefineHighlights()
  for [name, hl] in [['RgSelected', 'RgSelected'], ['RgCount', 'RgCount'],
                     ['RgMatch', 'RgMatch'], ['RgLineNr', 'RgLineNr'], ['RgSep', 'RgSep']]
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: hl, combine: false})
    endif
  endfor

  query = initial
  selected = 0
  results = []

  # Each popup has a 1-cell border on every side, so it occupies content + 2.
  # Two popups side by side must fill &columns exactly; height leaves room for
  # the cmdline (&cmdheight) so nothing is hidden behind it.
  var outer_h = &lines - &cmdheight
  var inner_h = outer_h - 2
  var left_outer = &columns * 2 / 5
  var right_outer = &columns - left_outer
  var left_w = left_outer - 2
  var right_w = right_outer - 2

  files_win = popup_create('', {
    line: 1, col: 1,
    minwidth: left_w, maxwidth: left_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    zindex: 200,
    wrap: false,
    scrollbar: false,
    filter: Filter,
    mapping: false,
    callback: (_, _) => Close(),
  })
  preview_win = popup_create('', {
    line: 1, col: left_outer + 1,
    minwidth: right_w, maxwidth: right_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    zindex: 200,
    wrap: false,
    scrollbar: false,
  })
  StartSearch()
enddef

command! -nargs=? Rg Open(<q-args>)
