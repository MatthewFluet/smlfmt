structure SeqLex: LEX =
struct

  (** ======================================================================
    * Some helpers
    *)

  val isValidFormatEscapeChar = Char.contains " \t\n\f\r"
  val isValidSingleEscapeChar = Char.contains "abtnvfr\\\""
  val isSymbolic = Char.contains "!%&$#+-/:<=>?@\\~`^|*"
  fun isDecDigit c = Char.isDigit c
  fun isHexDigit c = Char.isHexDigit c
  fun isLetter c = Char.isAlpha c
  fun isAlphaNumPrimeOrUnderscore c =
    Char.isAlphaNum c orelse c = #"_" orelse c = #"'"


  (** =====================================================================
    * STATE MACHINE
    *
    * This bunch of mutually-recursive functions implements an efficient
    * state machine. Each is named `loop_<STATE_NAME>`. The arguments are
    * always
    *   `loop_XXX acc stream [args]`
    * where
    *   `acc` is a token accumulator,
    *   `stream` is the rest of the input, and
    *   `args` is a state-dependent state (haha)
    *)

  fun stateMachine src =
    let
      fun mk x (i, j) = Token.make (Source.subseq src (i, j-i)) x
      fun mkr x (i, j) = Token.reserved (Source.subseq src (i, j-i)) x

      fun next1 s =
        if s < Source.length src then
          SOME (Source.nth src s)
        else
          NONE

      fun next2 s =
        if s < Source.length src - 1 then
          SOME (Source.nth src s, Source.nth src (s+1))
        else
          NONE

      fun loop_topLevel acc s =
        case next1 s of
          SOME #"(" =>
            loop_afterOpenParen acc (s+1)
        | SOME #")" =>
            loop_topLevel (mkr Token.CloseParen (s, s+1) :: acc) (s+1)
        | SOME #"[" =>
            loop_topLevel (mkr Token.OpenSquareBracket (s, s+1) :: acc) (s+1)
        | SOME #"]" =>
            loop_topLevel (mkr Token.CloseSquareBracket (s, s+1) :: acc) (s+1)
        | SOME #"{" =>
            loop_topLevel (mkr Token.OpenCurlyBracket (s, s+1) :: acc) (s+1)
        | SOME #"}" =>
            loop_topLevel (mkr Token.CloseCurlyBracket (s, s+1) :: acc) (s+1)
        | SOME #"," =>
            loop_topLevel (mkr Token.Comma (s, s+1) :: acc) (s+1)
        | SOME #";" =>
            loop_topLevel (mkr Token.Semicolon (s, s+1) :: acc) (s+1)
        | SOME #"_" =>
            loop_topLevel (mkr Token.Underscore (s, s+1) :: acc) (s+1)
        | SOME #"\"" =>
            loop_inString acc (s+1) {stringStart = s}
        | SOME #"~" =>
            loop_afterTwiddle acc (s+1)
        | SOME #"'" =>
            loop_alphanumId acc (s+1) {idStart = s, startsPrime = true}
        | SOME #"0" =>
            loop_afterZero acc (s+1)
        | SOME #"." =>
            loop_afterDot acc (s+1)
        | SOME c =>
            if isDecDigit c then
              loop_decIntegerConstant acc (s+1) {constStart = s}
            else if isSymbolic c then
              loop_symbolicId acc (s+1) {idStart = s}
            else if isLetter c then
              loop_alphanumId acc (s+1) {idStart = s, startsPrime = false}
            else
              loop_topLevel acc (s+1)
        | NONE =>
            (** DONE *)
            acc


      and loop_afterDot acc s =
        case next2 s of
          SOME (#".", #".") =>
            loop_topLevel
              (mkr Token.DotDotDot (s-1, 3) :: acc)
              (s+2)
        | SOME (c1, c2) =>
            raise Fail ("expected '...' but found '." ^ String.implode [c1,c2] ^ "'")
        | NONE =>
            raise Fail ("expected '...' but found end of file")



      and loop_symbolicId acc s (args as {idStart}) =
        case next1 s of
          SOME c =>
            if isSymbolic c then
              loop_symbolicId acc (s+1) args
            else
              loop_topLevel
                (mk Token.SymbolicId (idStart, s) :: acc)
                s
        | NONE =>
            (** DONE *)
            mk Token.SymbolicId (idStart, s) :: acc



      and loop_alphanumId acc s (args as {idStart, startsPrime}) =
        case next1 s of
          SOME #"." =>
            if startsPrime then
              raise Fail "structure identifiers cannot start with prime"
            else
              loop_continueLongIdentifier acc (s+1) {idStart=idStart}
        | SOME c =>
            (** SML's notion of alphanum is a little weird. *)
            if isAlphaNumPrimeOrUnderscore c then
              loop_alphanumId acc (s+1) args
            else
              loop_topLevel
                (mk Token.AlphanumId (idStart, s) :: acc)
                s
        | NONE =>
            (** DONE *)
            mk Token.AlphanumId (idStart, s) :: acc



      and loop_continueLongIdentifier acc s (args as {idStart}) =
        case next1 s of
          SOME c =>
            if isSymbolic c then
              loop_symbolicId acc (s+1) args
            else if isLetter c then
              loop_alphanumId acc (s+1) {idStart = idStart, startsPrime = false}
            else
              raise Fail "after qualifier, expected letter or symbol"
        | NONE =>
            raise Fail "unexpected end of qualified identifier"



      (** After seeing a twiddle, we might be at the beginning of an integer
        * constant, or we might be at the beginning of a symbolic-id.
        *
        * Note that seeing "0" next is special, because of e.g. "0x" used to
        * indicate the beginning of hex format.
        *)
      and loop_afterTwiddle acc s =
        case next1 s of
          SOME #"0" =>
            loop_afterTwiddleThenZero acc (s+1)
        | SOME c =>
            if isDecDigit c then
              loop_decIntegerConstant acc (s+1) {constStart = s - 1}
            else if isSymbolic c then
              loop_symbolicId acc (s+1) {idStart = s - 1}
            else
              loop_topLevel
                (mk Token.SymbolicId (s - 1, s) :: acc)
                s
        | NONE =>
            (** DONE *)
            mk Token.SymbolicId (s - 1, s) :: acc



      (** Comes after "~0"
        * This might be the middle or end of an integer constant. We have
        * to first figure out if the integer constant is hex format.
        *)
      and loop_afterTwiddleThenZero acc s =
        case next2 s of
          SOME (#"x", c) =>
            if isHexDigit c then
              loop_hexIntegerConstant acc (s+2) {constStart = s - 2}
            else
              loop_topLevel
                (mk Token.IntegerConstant (s - 2, s) :: acc)
                s
        | _ =>
        case next1 s of
          SOME #"." =>
            loop_realConstantAfterDot acc (s+1) {constStart = s - 2}
        | SOME c =>
            if isDecDigit c then
              loop_decIntegerConstant acc (s+1) {constStart = s - 2}
            else
              loop_topLevel
                (mk Token.IntegerConstant (s - 2, s) :: acc)
                s
        | NONE =>
            (** DONE *)
            mk Token.IntegerConstant (s - 2, s) :: acc



      (** After seeing "0", we're certainly at the beginning of some sort
        * of numeric constant. We need to figure out if this is an integer or
        * a word, and if it is hex or decimal format.
        *)
      and loop_afterZero acc s =
        case next2 s of
          SOME (#"x", c) =>
            if isHexDigit c then
              loop_hexIntegerConstant acc (s+2) {constStart = s - 1}
            else
              loop_topLevel (mk Token.IntegerConstant (s - 1, s) :: acc) s
        | _ =>
        case next1 s of
          SOME #"." =>
            loop_realConstantAfterDot acc (s+1) {constStart = s - 1}
        | SOME #"w" =>
            loop_afterZeroDubya acc (s+1)
        | SOME c =>
            if isDecDigit c then
              loop_decIntegerConstant acc (s+1) {constStart = s - 1}
            else
              loop_topLevel (mk Token.IntegerConstant (s - 1, s) :: acc) s
        | NONE =>
            (** DONE *)
            mk Token.IntegerConstant (s - 1, s) :: acc



      and loop_decIntegerConstant acc s (args as {constStart}) =
        case next1 s of
          SOME #"." =>
            loop_realConstantAfterDot acc (s+1) args
        | SOME c =>
            if isDecDigit c then
              loop_decIntegerConstant acc (s+1) args
            else
              loop_topLevel (mk Token.IntegerConstant (constStart, s) :: acc) s
        | NONE =>
            (** DONE *)
            mk Token.IntegerConstant (constStart, s) :: acc



      (** Immediately after the dot, we need to see at least one decimal digit *)
      and loop_realConstantAfterDot acc s (args as {constStart}) =
        case next1 s of
          SOME c =>
            if isDecDigit c then
              loop_realConstant acc (s+1) args
            else
              raise Fail ("while parsing real constant, expected decimal digit \
                          \but found '." ^ String.implode [c] ^ "'")
        | NONE =>
            raise Fail "real constant ends unexpectedly at end of file"


      (** Parsing the remainder of a real constant. This is already after the
        * dot, because the front of the real constant was already parsed as
        * an integer constant.
        *)
      and loop_realConstant acc s (args as {constStart}) =
        case next1 s of
          SOME #"E" =>
            raise Fail "real constants with exponents 'E' not supported yet"
        | SOME c =>
            if isDecDigit c then
              loop_realConstant acc (s+1) args
            else
              loop_topLevel
                (mk Token.RealConstant (constStart, s) :: acc)
                s
        | NONE =>
            mk Token.RealConstant (constStart, s) :: acc



      and loop_hexIntegerConstant acc s (args as {constStart}) =
        case next1 s of
          SOME c =>
            if isHexDigit c then
              loop_hexIntegerConstant acc (s+1) args
            else
              loop_topLevel (mk Token.IntegerConstant (constStart, s) :: acc) s
        | NONE =>
            (** DONE *)
            mk Token.IntegerConstant (constStart, s) :: acc



      and loop_decWordConstant acc s (args as {constStart}) =
        case next1 s of
          SOME c =>
            if isDecDigit c then
              loop_decWordConstant acc (s+1) args
            else
              loop_topLevel (mk Token.WordConstant (constStart, s) :: acc) s
        | NONE =>
            (** DONE *)
            mk Token.WordConstant (constStart, s) :: acc



      and loop_hexWordConstant acc s (args as {constStart}) =
        case next1 s of
          SOME c =>
            if isHexDigit c then
              loop_hexWordConstant acc (s+1) args
            else
              loop_topLevel (mk Token.WordConstant (constStart, s) :: acc) s
        | NONE =>
            (** DONE *)
            mk Token.WordConstant (constStart, s) :: acc



      (** Comes after "0w"
        * It might be tempting to think that this is certainly a word constant,
        * but that's not necessarily true. Here's some possibilities:
        *   0w5       -- word constant 5
        *   0wx5      -- word constant 5, in hex format
        *   0w        -- integer constant 0 followed by alphanum-id "w"
        *   0wx       -- integer constant 0 followed by alphanum-id "wx"
        *)
      and loop_afterZeroDubya acc s =
        case next2 s of
          SOME (#"x", c) =>
            if isHexDigit c then
              loop_hexWordConstant acc (s+2) {constStart = s - 2}
            else
              (** TODO: FIX: this is not quite right. Should
                * jump straight to identifier that starts with "wx"
                *)
              loop_topLevel
                (mk Token.IntegerConstant (s - 2, s - 1) :: acc)
                s
        | _ =>
        case next1 s of
          SOME c =>
            if isDecDigit c then
              loop_decWordConstant acc (s+1) {constStart = s - 2}
            else
              (** TODO: FIX: this is not quite right. Should
                * jump straight to identifier that starts with "w"
                *)
              loop_topLevel
                (mk Token.IntegerConstant (s - 2, s - 1) :: acc)
                s
        | NONE =>
            (** DONE *)
            mk Token.IntegerConstant (s - 2, s - 1) ::
            mk Token.AlphanumId (s - 1, s) ::
            acc


      (** An open-paren could just be a normal paren, or it could be the
        * start of a comment.
        *)
      and loop_afterOpenParen acc s =
        case next1 s of
          SOME #"*" =>
            loop_inComment acc (s+1) {commentStart = s - 1, nesting = 1}
        | SOME _ =>
            loop_topLevel (mkr Token.OpenParen (s - 1, s) :: acc) s
        | NONE =>
            (** DONE *)
            mkr Token.OpenParen (s - 1, s) :: acc



      and loop_inString acc s (args as {stringStart}) =
        case next1 s of
          SOME #"\\" (* " *) =>
            loop_inStringEscapeSequence acc (s+1) args
        | SOME #"\"" =>
            loop_topLevel
              (mk Token.StringConstant (stringStart, s+1) :: acc)
              (s+1)
        | SOME c =>
            if Char.isPrint c then
              loop_inString acc (s+1) args
            else
              raise Fail ("non-printable character at " ^ Int.toString (s))
        | NONE =>
            raise Fail ("unclosed string starting at " ^ Int.toString stringStart)



      (** Inside a string, and furthermore immediately inside a backslash *)
      and loop_inStringEscapeSequence acc s (args as {stringStart}) =
        case next1 s of
          SOME c =>
            if isValidSingleEscapeChar c then
              loop_inString acc (s+1) args
            else if isValidFormatEscapeChar c then
              loop_inStringFormatEscapeSequence acc (s+1) args
            else if c = #"^" then
              loop_inStringControlEscapeSequence acc (s+1) args
            else if c = #"u" then
              raise Fail "escape sequences \\uxxxx not supported yet"
            else if isDecDigit c then
              raise Fail "escape sequences \\ddd not supported yet"
            else
              loop_inString acc s args
        | NONE =>
            raise Fail ("unclosed string starting at " ^ Int.toString stringStart)



      (** Inside a string, and furthermore inside an escape sequence of
        * the form \^c
        *)
      and loop_inStringControlEscapeSequence acc s (args as {stringStart}) =
        case next1 s of
          SOME c =>
            if 64 <= Char.ord c andalso Char.ord c <= 95 then
              loop_inStringEscapeSequence acc (s+1) args
            else
              raise Fail ("invalid control escape sequence at " ^ Int.toString (s))
        | NONE =>
            raise Fail ("incomplete control escape sequence at " ^ Int.toString (s))



      (** Inside a string, and furthermore inside an escape sequence of the
        * form \f...f\ where each f is a format character (space, newline, tab,
        * etc.)
        *)
      and loop_inStringFormatEscapeSequence acc s (args as {stringStart}) =
        case next1 s of
          SOME #"\\" (*"*) =>
            loop_inString acc (s+1) args
        | SOME c =>
            if isValidFormatEscapeChar c then
              loop_inStringFormatEscapeSequence acc (s+1) args
            else
              raise Fail ("invalid format escape sequence at " ^ Int.toString (s))
        | NONE =>
            raise Fail ("incomplete format escape sequence at " ^ Int.toString (s))


      (** Inside a comment that started at `commentStart`
        * `nesting` is always >= 0 and indicates how many open-comments we've seen.
        *)
      and loop_inComment acc s {commentStart, nesting} =
        if nesting = 0 then
          loop_topLevel (mk Token.Comment (commentStart, s) :: acc) s
        else

        case next2 s of
          SOME (#"(", #"*") =>
            loop_inComment acc (s+2) {commentStart=commentStart, nesting=nesting+1}
        | SOME (#"*", #")") =>
            loop_inComment acc (s+2) {commentStart=commentStart, nesting=nesting-1}
        | _ =>

        case next1 s of
          SOME _ =>
            loop_inComment acc (s+1) {commentStart=commentStart, nesting=nesting}
        | NONE =>
            raise Fail ("unclosed comment starting at " ^ Int.toString commentStart)

    in
      Seq.fromList (List.rev (loop_topLevel [] 0))
    end



  (** =====================================================================
    * The lexer above is a bit sloppy, in that it doesn't always produce
    * all reserved words. So we clean up here.
    *
    * The function `clarifyClassOfSymbolic` catches reserved words that
    * were sloppily identified as `Token.SymbolicId`.
    *
    * Similarly, `clarifyClassOfAlphanum` handles sloppy `Token.AlphanumId`s
    *)

  (** look closer at the token [f(k) : i <= k < j] *)
  fun clarifyClassOfSymbolic str =
    case str of
      ":" => Token.Reserved Token.Colon
    | ":>" => Token.Reserved Token.ColonArrow
    | "|" => Token.Reserved Token.Bar
    | "=" => Token.Reserved Token.Equal
    | "=>" => Token.Reserved Token.FatArrow
    | "->" => Token.Reserved Token.Arrow
    | "#" => Token.Reserved Token.Hash
    | _ => Token.SymbolicId


  fun clarifyClassOfAlphanum str =
    let
      fun r rclass = Token.Reserved rclass
    in
      case str of
      (** Core *)
        "abstype" => r Token.Abstype
      | "and" => r Token.And
      | "andalso" => r Token.Andalso
      | "as" => r Token.As
      | "case" => r Token.Case
      | "datatype" => r Token.Datatype
      | "do" => r Token.Do
      | "else" => r Token.Else
      | "end" => r Token.End
      | "exception" => r Token.Exception
      | "fn" => r Token.Fn
      | "fun" => r Token.Fun
      | "handle" => r Token.Handle
      | "if" => r Token.If
      | "in" => r Token.In
      | "infix" => r Token.Infix
      | "infixr" => r Token.Infixr
      | "let" => r Token.Let
      | "local" => r Token.Local
      | "nonfix" => r Token.Nonfix
      | "of" => r Token.Of
      | "op" => r Token.Op
      | "open" => r Token.Open
      | "orelse" => r Token.Orelse
      | "raise" => r Token.Raise
      | "rec" => r Token.Rec
      | "then" => r Token.Then
      | "type" => r Token.Type
      | "val" => r Token.Val
      | "with" => r Token.With
      | "withtype" => r Token.Withtype
      | "while" => r Token.While
      (** Modules *)
      | "eqtype" => r Token.Eqtype
      | "functor" => r Token.Functor
      | "include" => r Token.Include
      | "sharing" => r Token.Sharing
      | "sig" => r Token.Sig
      | "signature" => r Token.Signature
      | "struct" => r Token.Struct
      | "structure" => r Token.Structure
      | "where" => r Token.Where

      (** Other *)
      | _ => Token.AlphanumId
    end


  (** ======================================================================
    * The final algorithm just invokes the state-machine loop and then
    * cleans up reserved words.
    *)

  fun tokens src =
    let
      val toks = stateMachine src

      fun replaceWithReserved (tok as {source=src, class}: Token.t) =
        { source = src
        , class =
            case class of
              Token.SymbolicId =>
                clarifyClassOfSymbolic (Source.toString src)
            | Token.AlphanumId =>
                clarifyClassOfAlphanum (Source.toString src)
            | _ => class
        }
    in
      Seq.map replaceWithReserved toks
    end

end
