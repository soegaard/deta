#lang scribble/manual

@(require scribble/example
          racket/format
          racket/runtime-path
          racket/sandbox
          (for-label db
                     deta
                     gregor
                     json
                     (except-in racket/base date date?)
                     racket/contract
                     racket/match
                     racket/sequence
                     racket/string
                     threading))

@title{@exec{deta}: Functional Database Mapping}
@author[(author+email "Bogdan Popa" "bogdan@defn.io")]

@defmodule[deta]

@(define (repo-link label)
   (hyperlink "https://github.com/Bogdanp/deta" label))

This library automatically maps database tables to Racket structs and
lets you perform CRUD operations on them as well as arbitrary queries.
Sort of like an ORM, but without associations and all the bad bits.

The API is currently fairly stable, but it may change before 1.0.
Watch the @repo-link{GitHub repository} if you want to stay on top of
potential changes.


@section[#:tag "principles"]{Principles}

The main principle backing this library is "explicitness without
tedium."  By that I mean that it should be crystal clear to someone
who is reading code that uses this library how the code maps to
database operations, while making the common cases of mapping data
between database tables and Racket structs straightforward and simple.

@subsection{Non-goals}

@itemlist[
  @item{@bold{Support for every SQL dialect.}  Despite the fact that
        both SQLite and PostgreSQL are currently supported by this
        library, the focus is on PostgreSQL and SQLite just serves as
        a check to ensure that nothing is @emph{too} PostgreSQL
        specific.}
  @item{@bold{Being a general purpose SQL DSL}.  For some queries you
        may have to resort to raw SQL or the @racketmodname[sql]
        library.  deta is very much an "80% solution."}
  @item{@bold{Being externally-extensible.}  The SQL AST as well as
        all of the dialect code is considered private and any new
        dialects (such as MySQL) will have to be added to the library
        itself.}
]

If you're down with that, then, by all means, carry on and read the
tutorial!


@section[#:tag "tutorial"]{Tutorial}

@; Blatantly copied from sql-lib!
@(begin
   (define-syntax-rule (interaction e ...) (examples #:label #f e ...))
   (define-runtime-path log-file "tutorial-log.rktd")
   (define log-mode (if (getenv "DETA_RECORD") 'record 'replay))
   (define (make-pg-eval log-file)
     (let ([ev (make-log-based-eval log-file log-mode)])
       (ev '(require db deta racket/contract racket/match racket/string threading))
       ev))
   (define db-eval (make-pg-eval log-file)))

deta builds upon the @racketmodname[db] library.  You will use deta to
generate your mappings and create queries, but the db library will be
doing the actual work of talking to the database and handling
transactions.

Let's start by creating a database connection in the usual way:

@interaction[
#:eval db-eval
(require db)

(code:line)
(define conn
  (postgresql-connect #:database "deta"
                      #:user     "deta"
                      #:password "deta"))
]

Next, let's define a schema for books:

@interaction[
#:eval db-eval
(require deta)

(code:line)
(define-schema book
  ([id id/f #:primary-key #:auto-increment]
   [title string/f #:contract non-empty-string? #:wrapper string-titlecase]
   [author string/f #:contract non-empty-string?]
   [published-on date/f]))
]

The above generates a struct named @racket[book] with fields for the
table's @racket[id], @racket[title], @racket[author] and @racket[published-on]
columns, an associated "smart constructor" called @racket[make-book]
and functional setter and updater functions for each field.

@interaction[
#:eval db-eval
(require gregor)

(code:line)
(define a-book
  (make-book #:title "To Kill a Mockingbird"
             #:author "Harper Lee"
             #:published-on (date 1960 7 11)))

(code:line)
(book-id a-book)
(book-title a-book)
(book-title
 (update-book-title a-book (lambda (t)
                             (string-append t "?"))))

(code:line)
(code:comment "schema entities are immutable so the above did not change a-book")
(book-title a-book)
]

We can use the schema to issue DDL commands to the database and create
the table:

@interaction[
#:eval db-eval
#:hidden
(drop-table! conn 'book)
]

@interaction[
#:eval db-eval
(create-table! conn 'book)
]

@(define north-uri "https://docs.racket-lang.org/north/index.html")
@margin-note{Note that while the DDL functionality is convenient for
the purposes of this tutorial, in real world projects you should
probably use something like @hyperlink[north-uri]{north} to manage
your database table schemas.}

Now that we have a table, we can insert the book that we created into
the database:

@interaction[
#:eval db-eval
(define saved-book
  (insert-one! conn a-book))

(code:line)
(book-id saved-book)
]

Let's insert a few more books:

@interaction[
#:eval db-eval
(void
 (insert! conn (make-book #:title "1984"
                          #:author "George Orwell"
                          #:published-on (date 1949 6 8))
               (make-book #:title "The Lord of the Rings"
                          #:author "J.R.R. Tolkien"
                          #:published-on (date 1954 7 29))
               (make-book #:title "The Catcher in the Rye"
                          #:author "J.D. Salinger"
                          #:published-on (date 1949 7 16))))
]

And now let's query for all of the books published before 1955:

@interaction[
#:eval db-eval
(require threading)

(code:line)
(for/list ([b (in-entities conn (~> (from book #:as b)
                                    (where (< b.published-on (date "1955-01-01")))
                                    (order-by ([b.published-on #:desc]))))])
  (book-title b))
]

Sweet!  Here's the query we just ran:

@interaction[
#:eval db-eval
(displayln
 (~> (from book #:as b)
     (where (< b.published-on (date "1955-01-01")))
     (order-by ([b.published-on #:desc]))))
]

What about dynamic parameters, you may ask?  Let's wrap the above
query in a function:

@interaction[
#:eval db-eval
(define (books-before year)
  (~> (from book #:as b)
      (where (< b.published-on ,(sql-date year 1 1)))
      (order-by ([b.published-on #:desc]))))

(code:line)
(for/list ([b (in-entities conn (books-before 1950))])
  (book-title b))

(code:line)
(for/list ([b (in-entities conn (books-before 1955))])
  (book-title b))
]

Any time the query combinators encounter an @racket[unquote], that
value gets replaced with a placeholder node in the query AST and, when
the query is eventually executed, the value is bound to its prepared
statement.  This makes it safe and easy to parameterize your queries
without having to worry about SQL injection attacks.

Oftentimes, you'll want to query data from the DB that doesn't match
your schema.  For example, let's say we want to grab the number of
books published by year from our database.  To do that, we can declare
a "virtual" schema -- one whose entities can't be persisted -- and
project our queries onto that schema.

@interaction[
#:eval db-eval
(define-schema book-stats
  #:virtual
  ([year date/f]
   [books integer/f]))

(code:line)
(define books-published-by-year
  (~> (from book #:as b)
      (select (as
                (cast (date_trunc "year" b.published-on) date)
                year)
              (count b.title))
      (group-by year)
      (order-by ([year]))
      (project-onto book-stats-schema)))

(code:line)
(for ([s (in-entities conn books-published-by-year)])
  (displayln (format "year: ~a books: ~a"
                     (book-stats-year s)
                     (book-stats-books s))))
]

If we hadn't wrapped our query with @racket[project-onto], then the
data would've been returned as @racket[values] which we could
destructure inside the @racket[for] loop, exactly like
@racket[in-query] from @racketmodname[db].

It's time to wind things down so let's delete all the books published
before 1950:

@interaction[
#:eval db-eval
(query-exec conn (delete (books-before 1950)))
]

Re-run the last query to make sure it worked:

@interaction[
#:eval db-eval
(for ([s (in-entities conn books-published-by-year)])
  (displayln (format "year: ~a books: ~a"
                     (book-stats-year s)
                     (book-stats-books s))))
]

That's all there is to it.  You now know the basics of deta.  Thanks
for following along!  If you want to learn more be sure to check out
the reference documentation below.


@section[#:tag "versus"]{Compared to *}

@subsection{Racquel}

Racquel takes a more classic approach to database mapping by being a
"real" ORM.  It is based on the class system, with entities (data
objects, as it calls them) being backed by mutable objects and having
support for associations via lazy loading.  deta's approach is nearly
the opposite of this by focusing on working with immutable structs,
avoiding associations altogether and any sort of lazy behaviour.

@subsection{sql}

@racketmodname[sql] is great at statically generating SQL queries.
The problem is that the generated queries are not composable at
runtime.  You have to write macros upon macros to handle composition
and I've found that that gets tedious quickly.

On top of giving you composable queries -- as you can hopefully see
from the tutorial --, deta also automatically maps CRUD operations to
structs, which is out of scope for @racketmodname[sql].


@section[#:tag "todos"]{TODOs}

@(define insert-link
   (hyperlink "https://www.postgresql.org/docs/11/sql-insert.html" "INSERT"))

@(define select-link
   (hyperlink "https://www.postgresql.org/docs/11/sql-select.html" "SELECT"))

@(define update-link
   (hyperlink "https://www.postgresql.org/docs/11/sql-update.html" "UPDATE"))

@(define delete-link
   (hyperlink "https://www.postgresql.org/docs/11/sql-delete.html" "DELETE"))

The following features are planned:

@itemlist[
  @item{Subqueries}
  @item{@tt{VALUES} expressions}
  @item{Column constraints for DDL}
]

The following query forms are not currently supported:

@itemlist[
  @item{@tt{WITH ... { @select-link | @update-link | @delete-link }  ...}}
  @item{@tt{@update-link ... FROM ...}}
  @item{@tt{@select-link ... HAVING ...}}
  @item{@tt{@select-link ... WINDOW ...}}
  @item{@tt{@select-link ... {UNION | INTERSECT | EXCEPT} ...}}
  @item{@tt{@select-link ... FOR UPDATE ...}}
]


@section[#:tag "reference"]{Reference}

@subsection{Query}
@defmodule[deta/query]

@subsubsection{DDL}

@defproc[(create-table! [conn connection?]
                        [schema (or/c schema? symbol?)]) void?]{

  Creates the table represented by @racket[schema] if it does not
  exist.  If @racket[schema] is a symbol, then it is looked up in the
  global registry.
}

@defproc[(drop-table! [conn connection?]
                      [schema (or/c schema? symbol?)]) void?]{

  Drops the table represented by @racket[schema] if it exists.
}

@subsubsection{Entity CRUD}

@defproc[(insert! [conn connection?]
                  [e entity?] ...) (listof entity?)]{

  Attempts to insert any newly-created entities into the database,
  returning the ones that were persisted.  Entities that have already
  been persisted are ignored.

  Raises a user error if any of the entities are based on virtual
  schemas.
}

@defproc[(insert-one! [conn connection?]
                      [e entity?]) (or/c false/c entity?)]{

  Attempts to insert @racket[e].  If it doesn't need to be persisted,
  then @racket[#f] is returned.

  Equivalent to:

  @racketblock[
    (match (insert! conn e)
      [(list e) e]
      [_ #f])
  ]
}

@defproc[(in-entities [conn connection?]
                      [q query?]
                      [#:batch-size batch-size (or/c exact-positive-integer? +inf.0) +inf.0]) sequence?]{

  Queries the database and, based on @racket[q], either returns a
  sequence of entities or a sequence of @racket[values].

  @racket[#:batch-size] controls how many rows to fetch from the
  databaase at a time.  It is analogous to @racket[in-query]'s
  @racket[#:fetch] argument.
}

@defproc[(lookup [conn connection?]
                 [q query?]) any]{

  Retrieves the first result for @racket[q].

  If there are no results then @racket[#f] is returned.
}

@defproc[(update! [conn connection?]
                  [e entity?] ...) (listof entity?)]{

  Attempts to update any modified entities.  Only updates the fields
  that have changed since the entities were retrieved from the
  database.  Returns those entities that have been updated.

  Raises a user error if any of the entities don't have a primary key
  field.
}

@defproc[(update-one! [conn connection?]
                      [e entity?]) (or/c false/c entity?)]{

  Attempts to update @racket[e].  If it doesn't need to be updated,
  then @racket[#f] is returned.

  Equivalent to:

  @racketblock[
    (match (update! conn e)
      [(list e) e]
      [_ #f])
  ]
}

@defproc[(delete! [conn connection?]
                  [e entity?] ...) (listof entity?)]{

  Attempts to delete any previously-persisted entities.  Returns those
  entities that have been deleted.

  Raises a user error if any of the entities don't have a primary key
  field.
}

@defproc[(delete-one! [conn connection?]
                      [e entity?]) (or/c false/c entity?)]{

  Attempts to delete @racket[e].  If it doesn't need to be deleted,
  then @racket[#f] is returned.

  Equivalent to:

  @racketblock[
    (match (delete! conn e)
      [(list e) e]
      [_ #f])
  ]
}


@subsubsection{Query Combinators}

@centered{
  @racketgrammar*[
    #:literals (array as and case else list or unquote)

    [q-expr (array q-expr ...)
            (as q-expr id)
            (and q-expr ...+)
            (case [q-expr q-expr] ...+)
            (case [q-expr q-expr] ...+
                  [else q-expr])
            (or q-expr ...+)
            (list q-expr ...)
            (unquote expr)
            ident
            boolean
            string
            number
            app]

    [app (q-expr q-expr ...)]

    [ident symbol]]
}

The grammar for SQL expressions.

Within an SQL expression, the following identifiers are treated
specially by the base (i.e. PostgreSQL) dialect.  These are inherited
by other dialects, but using them may result in invalid queries.

@tabular[
  #:sep @hspace[2]
  #:style 'boxed
  #:row-properties '(bottom-border)
  (list (list @bold{Identifier} "")
        (list @tt{array-concat}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(array-concat (array 1) (array 2 3))])
                      (list @bold{output:} @tt{ARRAY[1] || ARRAY[2, 3]}))])

        (list @tt{array-contains?}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(array-contains? (array 1 2) (array 1))])
                      (list @bold{output:} @tt{ARRAY[1, 2] @"@"> ARRAY[1]}))])

        (list @tt{array-overlap?}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(array-overlap? (array 1 2) (array 1))])
                      (list @bold{output:} @tt{ARRAY[1, 2] && ARRAY[1]}))])

        (list @tt{array-ref}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(array-ref (array 1 2) 1)])
                      (list @bold{output:} @tt{ARRAY[1, 2][1]}))])

        (list @tt{array-slice}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(array-slice (array 1 2) 1 3)])
                      (list @bold{output:} @tt{ARRAY[1, 2][1:3]}))])

        (list @tt{bitwise-not}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(bitwise-not 1)])
                      (list @bold{output:} @tt{~ 1}))])

        (list @tt{bitwise-and}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(bitwise-and 1 2)])
                      (list @bold{output:} @tt{1 & 2}))])

        (list @tt{bitwise-or}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(bitwise-or 1 2)])
                      (list @bold{output:} @tt{1 | 2}))])

        (list @tt{bitwise-xor}
              @tabular[
                #:sep @hspace[2]
                (list (list @bold{usage:}  @racket[(bitwise-xor 1 2)])
                      (list @bold{output:} @tt{1 # 2}))])
        )
]

@defproc[(query? [q any/c]) boolean?]{
  Returns @racket[#t] when @racket[q] is a query.
}

@defproc[(delete [q query?]) query?]{

  Converts @racket[q] into a @tt{DELETE} query, preserving its
  @tt{FROM} and @tt{WHERE} clauses.

  An error is raised if @racket[q] is anything other than a
  @tt{SELECT} query.
}

@defform[
  (from schema #:as alias)
  #:grammar
  [(schema (code:line string)
           (code:line id))]]{

  Creates a new @tt{SELECT} @racket[query?] from a schema or a table name.
}

@defform[(group-by query q-expr ...+)]{
  Adds a @tt{ORDER BY} clause to @racket[query].  If @racket[query]
  already has one, then the new columns are appended to the existing
  clause.
}

@defform*[
  ((join query maybe-type #:with table-name #:as alias #:on q-expr)
   (join query maybe-type #:with id #:as alias #:on q-expr))
  #:grammar
  ([maybe-type (code:line)
               (code:line #:inner)
               (code:line #:left)
               (code:line #:right)
               (code:line #:full)
               (code:line #:cross)])
  #:contracts
  ([table-name non-empty-string?])]{

  Adds a @tt{JOIN} to @racket[query].  If a join type is not provided,
  then the join defaults to an @tt{INNER} join.

  @examples[
    (require deta threading)

    (~> (from "posts" #:as p)
        (join #:left #:with "comments" #:as c #:on (= p.id c.post_id))
        (select p.* c.*))
  ]
}

@defform*[
  #:literals (unquote)
  ((limit query n)
   (limit query (unquote e)))]{
  Adds or replaces a @tt{LIMIT @racket[n]} clause to @racket[query].

  The first form raises a syntax error if @racket[n] is not an exact
  positive integer or 0.
}

@defform*[
  #:literals (unquote)
  ((offset query n)
   (offset query (unquote e)))]{
  Adds or replaces an @tt{OFFSET @racket[n]} clause to @racket[query].

  The first form raises a syntax error if @racket[n] is not an exact
  positive integer or 0.
}

@defform[
  (order-by query ([column maybe-direction] ...+))
  #:grammar
  [(maybe-direction (code:line)
                    (code:line #:asc)
                    (code:line #:desc))]]{

  Adds an @tt{ORDER BY} clause to @racket[query].  If @racket[query]
  already has one, then the new columns are appended to the existing
  clause.
}

@defproc[(project-onto [q query?]
                       [s schema?]) query?]{
  Changes the target schema for @racket[q] to @racket[s].
}

@defform[(returning query q-expr ...+)]{
  Adds a @tt{RETURNING} clause to @racket[query].  If @racket[query]
  already has one, then the new columns are appended to the existing
  clause.
}

@defform*[
  #:literals (_)
  ((select _ q-expr ...+)
   (select query q-expr ...+))
]{
  Refines the set of selected values in @racket[query].

  The first form (with the @racket[_]) generates a fresh query.

  @examples[
    (require deta)
    (select _ 1 2)
    (select (from "users" #:as u) u.username)
  ]
}

@defform[
  (update query assignment ...+)
  #:grammar
  [(assignment [column q-expr])]]{

  Converts @racket[query] into an @tt{UPDATE} query, preserving its
  @tt{FROM} clause, making it the target table for the update, and its
  @tt{WHERE} clause.

  An error is raised if @racket[q] is anything other than a
  @tt{SELECT} query.
}

@defform[(where query q-expr)]{
  Wraps the @tt{WHERE} clause in @racket[query] to the result of
  @tt{AND}-ing it with @racket[q-expr].
}

@defform[(or-where query q-expr)]{
  Wraps the @tt{WHERE} clause in @racket[query] to the result of
  @tt{OR}-ing it with @racket[q-expr].
}

@subsection{Schema}
@defmodule[deta/schema]

@defproc[(entity? [e any/c]) boolean?]{
  Returns @racket[#t] when @racket[e] is an instance of a schema
  struct (i.e. an "entity").
}

@defproc[(schema? [s any/c]) boolean?]{
  Returns @racket[#t] when @racket[s] is a schema.
}

@defform[(define-schema id
           maybe-table
           maybe-virtual
           (field-definition ...+)
           maybe-pre-persist-hook
           maybe-pre-delete-hook)
         #:grammar
         [(maybe-table (code:line)
                       (code:line #:table table-name))
          (maybe-virtual (code:line)
                         (code:line #:virtual))
          (maybe-pre-persist-hook (code:line)
                                  (code:line #:pre-persist-hook pre-persist-hook))
          (maybe-pre-delete-hook (code:line)
                                 (code:line #:pre-delete-hook pre-delete-hook))
          (field-definition (code:line [id field-type
                                        maybe-name
                                        maybe-primary-key
                                        maybe-auto-increment
                                        maybe-unique
                                        maybe-nullable
                                        maybe-contract
                                        maybe-wrapper])
                            (code:line [(id default) field-type
                                        maybe-name
                                        maybe-primary-key
                                        maybe-auto-increment
                                        maybe-unique
                                        maybe-nullable
                                        maybe-contract
                                        maybe-wrapper]))
          (maybe-name (code:line)
                      (code:line #:name field-name))
          (maybe-primary-key (code:line)
                             (code:line #:primary-key))
          (maybe-auto-increment (code:line)
                                (code:line #:auto-increment))
          (maybe-unique (code:line)
                        (code:line #:unique))
          (maybe-nullable (code:line)
                          (code:line #:nullable))
          (maybe-contract (code:line)
                          (code:line #:contract e))
          (maybe-wrapper (code:line)
                          (code:line #:wrapper e))]
         #:contracts
         ([table-name non-empty-string?]
          [field-name non-empty-string?]
          [field-type type?]
          [pre-persist-hook (-> entity? entity?)]
          [pre-delete-hook (-> entity? entity?)])]{

  Defines a schema named @racket[id].  The schema will have an
  associated struct with the same name and a smart constructor called
  @tt{make-@emph{id}}.  The struct's "dumb" constructor is hidden so
  that invalid entities cannot be created.

  For every defined field there will be an associated functional
  setter and updater named @tt{set-@emph{id}-@emph{field}} and
  @tt{update-@emph{id}-@emph{field}}, respectively.

  If a @racket[table-name] is provided, then that is used as the name
  for the table.  Otherwise, an "s" is appended to the schema id to
  pluralize it.  Currently, there are no other pluralization rules.

  If @racket[#:virtual] is provided, then the resulting schema's
  entities will not be able to be persisted, nor will the schema be
  registered in the global registry.

  The @racket[pre-persist-hook] is run before an entity is either
  @racket[insert!]ed or @racket[update!]d.

  The @racket[pre-delete-hook] is run before an entity is
  @racket[delete!]d.

  Hooks @emph{do not} run for arbitrary queries.

  A syntax error is raised if you declare a field as both a primary
  key and nullable.  Additionally, a syntax error is raised if a
  schema has multiple primary keys.

  Every type has an associated contract so the @racket[#:contract]
  option for fields is only necessary if you want to further restrict
  the values that a field can contain.

  When converting field names to SQL, dashes are replaced with
  underscores and field names that end in question marks drop their
  question mark and are prefixed with "is_".  @racket[admin?] becomes
  @racket[is_admin].

  Custom field names can be specified by providing a @racket[#:name]
  in the field definition.  Note, however, that the library does not
  currently translate between field names and custom column names
  within arbitrary queries.

  Example:

  @racketblock[
    (define-schema book
      ([id id/f #:primary-key #:auto-increment]
       [title string/f #:unique #:contract non-empty-string? #:wrapper string-titlecase]
       [author string/f #:contract non-empty-string?]))
  ]
}

@defform[(schema-out schema)]{
  Exports all bindings related to @racket[schema].

  @interaction[
  (module sub racket/base
    (require deta)
    (provide (schema-out album))

    (define-schema album
      #:virtual
      ([id id/f #:primary-key #:auto-increment]
       [title string/f]
       [band string/f])))

  (code:line)
  (require 'sub)
  (define an-album
    (make-album #:title "Led Zeppelin"
                #:band "Led Zeppelin"))

  (code:line)
  (album? an-album)
  (album-title an-album)
  (album-title (update-album-title an-album string-upcase))]
}


@subsection{Type}
@defmodule[deta/type]

These are all the field types currently supported by deta.  Note that
not all database backends support all of these types.

@subsubsection{Support Matrix}

Here are all the types and how they map to the different backends.

@tabular[
  #:sep @hspace[2]
  (list (list @bold{Field Type}       @bold{Racket Type}                   @bold{PostgreSQL Type}  @bold{SQLite Type})
        (list @racket[id/f]           @racket[exact-nonnegative-integer?]  @tt{INTEGER / SERIAL}   @tt{INTEGER}      )
        (list @racket[integer/f]      @racket[exact-integer?]              @tt{INTEGER}            @tt{INTEGER}      )
        (list @racket[real/f]         @racket[real?]                       @tt{REAL}               @tt{REAL}         )
        (list @racket[numeric/f]      @racket[(or/c rational? +nan.0)]     @tt{NUMERIC}            @tt{UNSUPPORTED}  )
        (list @racket[string/f]       @racket[string?]                     @tt{TEXT}               @tt{TEXT}         )
        (list @racket[binary/f]       @racket[bytes?]                      @tt{BLOB}               @tt{BLOB}         )
        (list @racket[symbol/f]       @racket[symbol?]                     @tt{TEXT}               @tt{TEXT}         )
        (list @racket[boolean/f]      @racket[boolean?]                    @tt{BOOLEAN}            @tt{INTEGER}      )
        (list @racket[date/f]         @racket[date-provider?]              @tt{DATE}               @tt{TEXT}         )
        (list @racket[time/f]         @racket[time-provider?]              @tt{TIME}               @tt{TEXT}         )
        (list @racket[datetime/f]     @racket[datetime-provider?]          @tt{TIMESTAMP}          @tt{TEXT}         )
        (list @racket[datetime-tz/f]  @racket[moment-provider?]            @tt{TIMESTMAPTZ}        @tt{TEXT}         )
        (list @racket[array/f]        @racket[vector?]                     @tt{ARRAY}              @tt{UNSUPPORTED}  )
        (list @racket[json/f]         @racket[jsexpr?]                     @tt{JSON}               @tt{UNSUPPORTED}  )
        (list @racket[jsonb/f]        @racket[jsexpr?]                     @tt{JSONB}              @tt{UNSUPPORTED}  )
        )]

@subsubsection{Types}

@deftogether[
  (@defproc[(type? [v any/c]) boolean?]
   @defthing[id/f type?]
   @defthing[integer/f type?]
   @defthing[real/f type?]
   @defproc[(numeric/f [precision exact-integer?]
                       [scale exact-integer?]) type?]
   @defthing[string/f type?]
   @defthing[binary/f type?]
   @defthing[symbol/f type?]
   @defthing[boolean/f type?]
   @defthing[date/f type?]
   @defthing[time/f type?]
   @defthing[datetime/f type?]
   @defthing[datetime-tz/f type?]
   @defproc[(array/f [t type?]) type?]
   @defthing[json/f type?]
   @defthing[jsonb/f type?])]{

  The various types that deta supports.
}


@subsection[#:tag "changelog"]{Changelog}

@subsubsection{@exec{v0.1.0} -- 2019-07-19}

@bold{Added:}
@itemlist[
  @item{Support for @racket[join]s}
]

@bold{Changed:}
@itemlist[
  @item{
    @racket[order-by], @racket[group-by] and @racket[returning] were
    changed to always append themselves to existing clauses, if any
  }
  @item{@racket[and-where] was renamed to @racket[where]}
]

@bold{Fixed:}
@itemlist[
  @item{Loosened the return contract on @racket[lookup] to @racket[any]}
]
