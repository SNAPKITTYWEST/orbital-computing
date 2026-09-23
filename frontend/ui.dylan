Module: visual-workplace-ui
Synopsis: Object model for the Visual Workplace front end.
          Mirrors ColorForth words: shell, menubar, dock, termux-pane,
          agent-pane, c-live, key-enter, open-file, do-gcc.

define class <c-glow-state> (<object>)
  slot glow-active? :: <boolean> = #f,
    init-keyword: active?:;
  slot glow-compile-boost? :: <boolean> = #f,
    init-keyword: compile-boost?:;
end class <c-glow-state>;

define class <menubar> (<object>)
  constant slot menubar-app-name :: <byte-string> = "Workbench",
    init-keyword: app-name:;
  slot menubar-clock :: <byte-string> = "",
    init-keyword: clock:;
end class <menubar>;

define class <dock> (<object>)
  slot dock-active-icon :: <symbol> = #"workbench",
    init-keyword: active:;
end class <dock>;

define class <navigator-pane> (<object>)
  slot navigator-filter :: <byte-string> = "",
    init-keyword: filter:;
  slot navigator-selection :: false-or(<byte-string>) = #f,
    init-keyword: selection:;
end class <navigator-pane>;

define class <editor-pane> (<object>)
  slot editor-path :: false-or(<byte-string>) = #f,
    init-keyword: path:;
  slot editor-buffer :: <byte-string> = "",
    init-keyword: buffer:;
  slot editor-has-c-glow? :: <boolean> = #f;
end class <editor-pane>;

define class <termux-pane> (<object>)
  slot termux-cwd :: <byte-string>
    = "/data/data/com.termux/files/home/workspace",
    init-keyword: cwd:;
  slot termux-history :: <stretchy-vector> = make(<stretchy-vector>);
  slot termux-aout? :: <boolean> = #f;
  constant slot termux-glow :: <c-glow-state> = make(<c-glow-state>);
  slot termux-files :: <string-table> = make(<string-table>);
end class <termux-pane>;

define class <syscall-agent> (<object>)
  slot agent-log :: <stretchy-vector> = make(<stretchy-vector>);
  constant slot agent-name :: <byte-string> = "Grok Bot · syscall agent";
end class <syscall-agent>;

define class <workbench-window> (<object>)
  constant slot workbench-navigator :: <navigator-pane>
    = make(<navigator-pane>);
  constant slot workbench-editor :: <editor-pane>
    = make(<editor-pane>);
  slot workbench-termux :: false-or(<termux-pane>) = #f;
  slot workbench-agent :: false-or(<syscall-agent>) = #f;
  slot workbench-title :: <byte-string> = "Workbench",
    init-keyword: title:;
end class <workbench-window>;

define class <visual-workplace> (<object>)
  constant slot workplace-title :: <byte-string> = "Visual Workplace",
    init-keyword: title:;
  constant slot workplace-menubar :: <menubar> = make(<menubar>);
  constant slot workplace-dock :: <dock> = make(<dock>);
  constant slot workplace-workbench :: <workbench-window>
    = make(<workbench-window>);
end class <visual-workplace>;

/// --- Generics (protocol) ------------------------------------------------

define generic open-file!
    (wb :: <workbench-window>, path :: <byte-string>) => ();

define generic compile-c!
    (termux :: <termux-pane>, agent :: <syscall-agent>,
     source :: <byte-string>) => ();

define generic set-glow!
    (glow :: <c-glow-state>, on? :: <boolean>,
     #key compile-boost? :: <boolean> = #f) => ();

define generic handle-key-enter!
    (termux :: <termux-pane>, agent :: <syscall-agent>,
     line :: <byte-string>) => ();

define generic agent-ask!
    (agent :: <syscall-agent>, question :: <byte-string>) => ();

define generic mount-termux-agent-screen!
    (wb :: <workbench-window>) => ();

/// --- Methods ------------------------------------------------------------

define method set-glow!
    (glow :: <c-glow-state>, on? :: <boolean>,
     #key compile-boost? :: <boolean> = #f) => ()
  glow.glow-active? := on?;
  glow.glow-compile-boost? := on? & compile-boost?;
end method set-glow!;

define method looks-like-c? (text :: <byte-string>) => (yes? :: <boolean>)
  // Educational heuristic — mirrors ColorForth looks-like-c?
  subsequence-position(text, "#include")
    | subsequence-position(text, "int main")
    | subsequence-position(text, "printf")
    | subsequence-position(text, ".c")
end method looks-like-c?;

define method open-file!
    (wb :: <workbench-window>, path :: <byte-string>) => ()
  let ed = wb.workbench-editor;
  ed.editor-path := path;
  let c? = looks-like-c?(path) | subsequence-position(path, ".c");
  ed.editor-has-c-glow? := c?;
  if (wb.workbench-termux & c?)
    set-glow!(wb.workbench-termux.termux-glow, #t);
  end if;
  wb.workbench-navigator.navigator-selection := path;
end method open-file!;

define method agent-post!
    (agent :: <syscall-agent>, who :: <byte-string>, text :: <byte-string>)
 => ()
  add!(agent.agent-log, pair(who, text));
end method agent-post!;

define method compile-c!
    (termux :: <termux-pane>, agent :: <syscall-agent>,
     source :: <byte-string>) => ()
  set-glow!(termux.termux-glow, #t);
  agent-post!(agent, "syscall",
              concatenate("execve(\"/usr/bin/gcc\", [\"gcc\", \"",
                          source, "\"], …) = 0"));
  agent-post!(agent, "syscall",
              concatenate("openat(AT_FDCWD, \"", source, "\", O_RDONLY) = 3"));
  agent-post!(agent, "syscall", "execve(\"/usr/bin/as\", …) = 0");
  agent-post!(agent, "syscall", "execve(\"/usr/bin/ld\", …) = 0");
  termux.termux-aout? := #t;
  set-glow!(termux.termux-glow, #t, compile-boost?: #t);
  agent-post!(agent, "Grok Bot",
              "Compile path clean. Binary linked; PROT_EXEC mapping observed. Run ./a.out");
end method compile-c!;

define method handle-key-enter!
    (termux :: <termux-pane>, agent :: <syscall-agent>,
     line :: <byte-string>) => ()
  add!(termux.termux-history, line);
  if (looks-like-c?(line))
    set-glow!(termux.termux-glow, #t);
    agent-post!(agent, "Grok Bot", "C tokens on the wire — glow engaged.");
  elseif (subsequence-position(line, "gcc")
            | subsequence-position(line, "clang"))
    compile-c!(termux, agent, "hello.c");
  elseif (subsequence-position(line, "help"))
    agent-post!(agent, "Grok Bot",
                "Termux accepts help, ls, cat, gcc/clang, ./a.out.");
  else
    agent-post!(agent, "syscall",
                concatenate("execve(\"/bin/", line, "\", …) = 0"));
  end if;
end method handle-key-enter!;

define method agent-ask!
    (agent :: <syscall-agent>, question :: <byte-string>) => ()
  agent-post!(agent, "you", question);
  let q = as-lowercase(question);
  let answer
    = case
        subsequence-position(q, "write")
          => "write(fd, buf, n) copies n bytes to a file descriptor.";
        subsequence-position(q, "glow")
          => "Termux chrome pulses when a .c file is active; compile boosts cyan.";
        subsequence-position(q, "compile") | subsequence-position(q, "gcc")
          => "Compile flow: preprocess → cc1 → as → ld.";
        otherwise
          => "Trace tip: clone → execve → open/read/write → exit. Ask about a syscall.";
      end case;
  agent-post!(agent, "Grok Bot", answer);
end method agent-ask!;

define method mount-termux-agent-screen!
    (wb :: <workbench-window>) => ()
  wb.workbench-termux := make(<termux-pane>);
  wb.workbench-agent := make(<syscall-agent>);
  element-setter("hello.c", wb.workbench-termux.termux-files,
    "#include <stdio.h>\nint main(void) {\n  printf(\"Hello from Visual Workplace\\n\");\n  return 0;\n}\n");
  agent-post!(wb.workbench-agent, "Grok Bot",
              "Grok Bot online — sitting on clone/execve/open/write.");
  wb.workbench-title := "Termux · Syscall Agent";
end method mount-termux-agent-screen!;
