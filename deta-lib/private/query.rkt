#lang racket/base

(require db
         racket/contract
         racket/match
         racket/struct
         "adapter/adapter.rkt"
         "adapter/postgresql.rkt"
         (prefix-in ast: "ast.rkt")
         "connection.rkt"
         "field.rkt"
         "schema.rkt")

;; struct ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide
 make-empty-query
 (struct-out query))

(struct query (schema stmt)
  #:transparent
  #:property prop:statement
  (lambda (self c)
    (define adapter (connection-adapter c))
    (define-values (query args)
      (adapter-emit-query adapter (query-stmt self)))

    (define prepared
      (prepare c query))

    (cond
      [(null? args) prepared]
      [else (bind-prepared-statement prepared args)]))

  #:property prop:custom-write
  (make-constructor-style-printer
   (lambda (self) 'query)
   (lambda (self)
     (define-values (query args)
       (adapter-emit-query postgresql-adapter (query-stmt self)))
     (cons query args))))

(define (make-empty-query)
  (query #f (ast:make-select)))


;; dynamic ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide
 and-where
 as
 delete
 from
 group-by
 limit
 offset
 or-where
 order-by
 project-onto
 returning
 select
 update
 where)

(define/contract (as e name)
  (-> ast:expr? (or/c string? symbol?) ast:as?)
  (ast:as e (cond
              [(string? name) name]
              [(symbol? name) (symbol->string name)])))

(define/contract (delete q)
  (-> query? query?)
  (match q
    [(query schema (and (struct* ast:select ([from from] [where where])) stmt))
     (query schema (ast:make-delete
                    #:from from
                    #:where where))]))

(define/contract (from schema-or-name #:as alias)
  (-> (or/c schema? string? symbol?) #:as symbol? query?)

  (define alias:str (symbol->string alias))
  (define-values (schema table-name columns)
    (cond
      [(string? schema-or-name)
       (values #f schema-or-name null)]

      [else
       (define schema (schema-registry-lookup schema-or-name))
       (values schema
               (schema-table schema)
               (for/list ([f (in-list (schema-fields schema))])
                 (ast:column (ast:qualified alias:str (field-name f)))))]))

  (query schema
         (ast:make-select
          #:columns columns
          #:from (ast:from (ast:as (ast:table table-name) alias:str)))))

(define/contract (select q column0 . columns)
  (-> query? ast:expr? ast:expr? ... query?)
  (match q
    [(query _ stmt)
     (query #f (struct-copy ast:select stmt [columns (cons column0 columns)]))]))

(define/contract (limit q n)
  (-> query? exact-integer? query?)
  (match q
    [(query schema stmt)
     (query schema (struct-copy ast:select stmt [limit (ast:limit n)]))]))

(define/contract (group-by q column0 . columns)
  (-> query? ast:expr? ast:expr? ... query?)
  (match q
    [(query schema stmt)
     (query schema (struct-copy ast:select stmt [group-by (ast:group-by (cons column0 columns))]))]))

(define/contract (offset q n)
  (-> query? exact-integer? query?)
  (match q
    [(query schema stmt)
     (query schema (struct-copy ast:select stmt [offset (ast:offset n)]))]))

(define order-by-pair/c
  (cons/c ast:expr? (or/c 'asc 'desc)))

(define/contract (order-by q pair0 . pairs)
  (-> query? order-by-pair/c order-by-pair/c ... query?)
  (match q
    [(query schema stmt)
     (query schema (struct-copy ast:select stmt [order-by (ast:order-by (cons pair0 pairs))]))]))

(define/contract (project-onto q s)
  (-> query? schema? query?)
  (struct-copy query q [schema s]))

(define/contract (returning q e0 . es)
  (-> query? ast:expr? ast:expr? ... query?)
  (match q
    [(query schema (and (? ast:insert?) stmt))
     (query schema (struct-copy ast:insert stmt [returning (ast:returning (cons e0 es))]))]

    [(query schema (and (? ast:update?) stmt))
     (query schema (struct-copy ast:update stmt [returning (ast:returning (cons e0 es))]))]

    [(query schema (and (? ast:delete?) stmt))
     (query schema (struct-copy ast:delete stmt [returning (ast:returning (cons e0 es))]))]))

(define/contract (update q . ss)
  (-> query? (cons/c ast:expr? ast:expr?) ... query?)
  (match q
    [(query schema (struct* ast:select ([from (ast:from table)]
                                        [where where])))
     (query schema (ast:make-update
                    #:table table
                    #:assignments (ast:assignments ss)
                    #:where where))]))

(define/contract (where q e)
  (-> query? ast:expr? query?)
  (match q
    [(query schema (and (? ast:select?) stmt))
     (query schema (struct-copy ast:select stmt [where (ast:where e)]))]

    [(query schema (and (? ast:update?) stmt))
     (query schema (struct-copy ast:update stmt [where (ast:where e)]))]

    [(query schema (and (? ast:delete?) stmt))
     (query schema (struct-copy ast:delete stmt [where (ast:where e)]))]))

(define/contract (and-where q e)
  (-> query? ast:expr? query?)
  (match q
    [(query schema (and (struct* ast:select ([where #f])) stmt))
     (query schema (struct-copy ast:select stmt [where e]))]

    [(query schema (and (struct* ast:update ([where #f])) stmt))
     (query schema (struct-copy ast:update stmt [where e]))]

    [(query schema (and (struct* ast:delete ([where #f])) stmt))
     (query schema (struct-copy ast:delete stmt [where e]))]

    [(query schema (and (struct* ast:select ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:select stmt [where (ast:where (ast:app (ast:ident 'and) (list e0 e)))]))]

    [(query schema (and (struct* ast:update ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:update stmt [where (ast:where (ast:app (ast:ident 'and) (list e0 e)))]))]

    [(query schema (and (struct* ast:delete ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:delete stmt [where (ast:where (ast:app (ast:ident 'and) (list e0 e)))]))]))

(define/contract (or-where q e)
  (-> query? ast:expr? query?)
  (match q
    [(query schema (and (struct* ast:select ([where #f])) stmt))
     (query schema (struct-copy ast:select stmt [where e]))]

    [(query schema (and (struct* ast:update ([where #f])) stmt))
     (query schema (struct-copy ast:update stmt [where e]))]

    [(query schema (and (struct* ast:delete ([where #f])) stmt))
     (query schema (struct-copy ast:delete stmt [where e]))]

    [(query schema (and (struct* ast:select ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:select stmt [where (ast:where (ast:app (ast:ident 'or) (list e0 e)))]))]

    [(query schema (and (struct* ast:update ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:update stmt [where (ast:where (ast:app (ast:ident 'or) (list e0 e)))]))]

    [(query schema (and (struct* ast:delete ([where (ast:where e0)])) stmt))
     (query schema (struct-copy ast:delete stmt [where (ast:where (ast:app (ast:ident 'or) (list e0 e)))]))]))