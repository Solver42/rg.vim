vim9script

# rg.vim - full-screen live grep picker.
#
#   :Rg          open the picker in the current directory
#   :Rg {text}   open it with an initial query
#
# Left pane : files that contain a match (with match counts)
# Right pane: matches in the highlighted file, with context lines
#
# Keys:  type to filter   <BS>/<C-h> delete
#        <C-n>/<Down>/<C-j> next file   <C-p>/<Up>/<C-k> previous file
#        <C-d>/<C-f> scroll preview down   <C-b>/<C-u> scroll preview up
#        <CR> open file at first match   <Esc>/<C-c> close

if exists('g:loaded_rg_vim')
  finish
endif
g:loaded_rg_vim = 1

const CONTEXT = get(g:, 'rg_context', 2)       # lines shown before/after a match
const MAX_FILES = get(g:, 'rg_max_files', 500) # cap on listed files
const MAX_MATCHES = get(g:, 'rg_max_matches', 30) # cap on matches shown per file

if !executable('rg')
  echoerr 'rg.vim requires ripgrep (rg) to be installed and on your PATH.'
  finish
endif

# ---------------------------------------------------------------------------
# State (one picker at a time)
# ---------------------------------------------------------------------------
var query = ''
var results: list<dict<any>> = []   # [{file: str, count: number, lines: list<number>, has_count: bool}]
var selected = 0
var search_id = 0                   # bumped per search; late results from a
                                     # stopped search are discarded on arrival
var live_jobs: list<job> = []        # keeps every in-flight job referenced so
                                      # Vim can't drop it before exit_cb fires
                                      # (see StartSearch() for why this exists)
var root = ''                        # cwd captured once when the picker opens;
                                      # every path is resolved against this,
                                      # not the live cwd, which can change
                                      # under us (e.g. after OpenSelected())
var files_win = 0
var preview_win = 0

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
  highlight default link RgCursor Cursor
enddef

# ---------------------------------------------------------------------------
# Searching
# ---------------------------------------------------------------------------

# Command that lists "file:line:text" for every matching line, or the file
# list when the query is empty.
def SearchCmd(): list<string>
  # Extra flags from the user's vimrc, e.g.
  #   g:rg_args = ['--glob', '!*.png', '--hidden']
  var extra: list<string> = get(g:, 'rg_args', [])
  if query == ''
    return ['rg', '--files', '--color=never'] + extra
  endif
  return ['rg', '--line-number', '--no-heading', '--with-filename', '--color=never',
    '--smart-case', '--fixed-strings', '--max-columns=500'] + extra + ['--', query]
enddef

def StartSearch()
  search_id += 1
  var this_id = search_id
  var lines: list<string> = []
  var j = job_start(SearchCmd(), {
    out_cb: (_, line) => add(lines, line),
    exit_cb: (_, _) => Finished(this_id, lines),
    out_mode: 'nl',
    # IMPORTANT: rg searches stdin instead of the directory when stdin is a
    # pipe, and job_start() gives jobs an open pipe by default -- so without
    # this the job waits forever for input and never exits.
    in_io: 'null',
    err_io: 'null',
    cwd: root,
  })
  # Older searches are never stopped, just outdated: Finished() drops their
  # results via this_id. Keeping the job objects referenced is cheap insurance
  # against Vim collecting a job before its exit_cb fires.
  add(live_jobs, j)
enddef

# Group grep output by file. Runs when a search job exits. this_id/lines
# belong to that one search, so a job stopped mid-flight (superseded by a
# newer keystroke) can still finish and call this, but this_id will no
# longer match search_id and the stale result is dropped.
def Finished(this_id: number, lines: list<string>)
  live_jobs = filter(live_jobs, (_, j) => job_status(j) ==# 'run')
  if this_id != search_id
    return
  endif
  var by_file: dict<dict<any>> = {}
  var order: list<string> = []
  for l in lines
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
        by_file[f] = {file: f, count: 0, lines: [], has_count: true}
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

  # Line 1 is always the prompt: "> query█". A drawn block stands in for a
  # real cursor, since popups never receive Vim's actual terminal cursor.
  var prompt = '> ' .. query
  var prompt_pad = repeat(' ', max([width - strwidth(prompt) - 1, 0]))
  add(text, {text: prompt .. '█' .. prompt_pad, props: [
    {col: 1, length: len(prompt), type: 'RgPrompt'},
    {col: len(prompt) + 1, length: len('█'), type: 'RgCursor'},
  ]})
  add(text, {text: repeat('─', width), props: [{col: 1, length: len(repeat('─', width)), type: 'RgSep'}]})

  for i in range(len(results))
    var r = results[i]
    # r.count reflects whichever search last populated `results`, which can
    # be one keystroke behind `query` for the single interim frame between
    # a keystroke's immediate repaint and its search job completing. Only
    # trust r.count when it was actually computed for the CURRENT query
    # (r.count is meaningless -- always 0 -- on results from an empty-query
    # listing). has_key guards that: real search results carry has_count.
    var count = query == '' || !has_key(r, 'has_count') ? '' : ' ' .. r.count
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
  if empty(results)
    add(text, {text: ' no matches', props: [{col: 1, length: 11, type: 'RgCount'}]})
  endif
  popup_settext(files_win, text)
  # Keep the selection scrolled into view. Selected file is at buffer line
  # (selected + 3): 2 header lines above it.
  win_execute(files_win, 'normal! ' .. (selected + 3) .. 'Gzz')
  popup_setoptions(files_win, {title: ' rg (' .. len(results) .. ' files' .. ') '})
enddef

# rg's own rule: a file is binary if its first bytes contain a NUL.
def IsBinary(path: string): bool
  # readfile() is declared to return list<string>, but with 'B' it returns a
  # blob; `any` stops Vim9's compile-time check from rejecting head[i] == 0.
  var head: any = readfile(path, 'B', 8192)
  for i in range(len(head))
    if head[i] == 0
      return true
    endif
  endfor
  return false
enddef

def RenderPreview()
  if empty(results)
    popup_settext(preview_win, '')
    return
  endif
  var r = results[selected]
  # r.file is relative (rg's own output). Resolve against the root captured
  # at picker-open time, not the live cwd -- see `root`'s declaration.
  var path = root .. '/' .. r.file
  if !filereadable(path)
    popup_settext(preview_win, '')
    return
  endif

  if IsBinary(path)
    popup_settext(preview_win, ' binary file')
    popup_setoptions(preview_win, {title: ' ' .. r.file .. ' '})
    return
  endif

  var file_lines = readfile(path, '', 5000)
  var total = len(file_lines)
  var text: list<any> = []
  var digits = len(string(total))

  # Plain top-of-file preview when there's no query, or when `results` is
  # still the file listing from before the current query's search finished
  # (those entries have no match lines to show).
  var plain = query == '' || empty(r.lines)
  var hits = plain ? [1] : r.lines[: MAX_MATCHES - 1]
  var maxw = popup_getpos(preview_win).core_width

  # Build merged ranges of [first, last] line numbers to display.
  var ranges: list<list<number>> = []
  for h in hits
    var lo = max([h - CONTEXT, 1])
    var hi = min([h + CONTEXT, total])
    if plain
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
      add(text, {text: repeat('─', maxw), props: [{col: 1, length: len(repeat('─', maxw)), type: 'RgSep'}]})
    endif
    for n in range(ranges[idx][0], ranges[idx][1])
      var prefix = printf('%' .. digits .. 'd ', n)
      var line = substitute(file_lines[n - 1], '\t', '  ', 'g')
      line = substitute(line, '[[:cntrl:]]', '?', 'g')
      # Clip to the pane ourselves so the window never has to scroll
      # horizontally: long lines are cut on the right, starts always visible.
      line = strcharpart(line, 0, max([maxw - strwidth(prefix), 0]))
      var props = [{col: 1, length: len(prefix), type: 'RgLineNr'}]
      if !plain
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
  popup_setoptions(preview_win, {title: ' ' .. r.file .. ' '})
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
  # Same reasoning as RenderPreview(): resolve against the captured root,
  # not whatever the live cwd is by the time Enter is pressed.
  var path = root .. '/' .. r.file
  Close()
  execute 'edit ' .. fnameescape(path)
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
  # Any search job still running at this point will finish on its own and
  # call Finished(), but Render() bails out immediately once files_win is 0
  # (above), so a late result from a closed picker is harmlessly ignored.
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
  elseif key == "\<C-b>" || key == "\<C-u>"
    win_execute(preview_win, "normal! \<C-u>")
  elseif key == "\<BS>" || key == "\<C-h>" || key == "\<Del>"
    query = strcharpart(query, 0, max([strchars(query) - 1, 0]))
    selected = 0
    RenderFiles()  # repaint the prompt line immediately; StartSearch()'s
                    # own completion will refresh the result rows shortly
    StartSearch()
  elseif strchars(key) == 1 && char2nr(key) >= 32
    query ..= key
    selected = 0
    RenderFiles()  # same: don't wait on the job to show what was typed
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
                     ['RgMatch', 'RgMatch'], ['RgLineNr', 'RgLineNr'], ['RgSep', 'RgSep'],
                     ['RgPrompt', 'RgPrompt'], ['RgCursor', 'RgCursor']]
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: hl, combine: false})
    endif
  endfor

  query = initial
  selected = 0
  results = []
  root = getcwd()  # captured once, here, and used for every path from now
                    # on -- not re-read later, since the live cwd can change
                    # under us while the picker is open (e.g. a BufEnter
                    # autocommand elsewhere in the user's config)

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
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
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
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    zindex: 200,
    wrap: false,
    scrollbar: false,
  })
  StartSearch()
enddef

command! -nargs=? -bar Rg Open(<q-args>)
