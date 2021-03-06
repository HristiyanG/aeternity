%%%-------------------------------------------------------------------
%%% @copyright (C) 2019, Aeternity Anstalt
%%% @doc
%%% ADT for the engine state
%%% @end
%%%-------------------------------------------------------------------
-module(aefa_engine_state).

-export([ new/4
        ]).

%% Getters
-export([ accumulator/1
        , accumulator_stack/1
        , bbs/1
        , call_stack/1
        , caller/1
        , chain_api/1
        , contracts/1
        , current_bb/1
        , current_contract/1
        , current_function/1
        , functions/1
        , gas/1
        , logs/1
        , memory/1
        , trace/1
        ]).

%% Setters
-export([ set_accumulator/2
        , set_accumulator_stack/2
        , set_bbs/2
        , set_call_stack/2
        , set_caller/2
        , set_chain_api/2
        , set_contracts/2
        , set_current_bb/2
        , set_current_contract/2
        , set_current_function/2
        , set_functions/2
        , set_gas/2
        , set_logs/2
        , set_memory/2
        , set_trace/2
        ]).

%% More complex stuff
-export([ current_bb_instructions/1
        , dup_accumulator/1
        , dup_accumulator/2
        , drop_accumulator/2
        , pop_accumulator/1
        , push_accumulator/2
        , push_arguments/2
        , push_env/2
        , push_return_address/1
        , spend_gas/2
        , update_for_remote_call/3
        ]).

-ifdef(TEST).
-export([ add_trace/2
        ]).
-endif.

-include_lib("aebytecode/include/aeb_fate_data.hrl").
-include("../../aecontract/include/aecontract.hrl").

-type void_or_fate() :: ?FATE_VOID | aeb_fate_data:fate_type().
-type void_or_address() :: ?FATE_VOID | aeb_fate_data:fate_address().

-record(es, { accumulator       :: void_or_fate()
            , accumulator_stack :: [aeb_fate_data:fate_type()]
            , bbs               :: map()
            , call_stack        :: [term()] %% TODO: Better type
            , caller            :: aeb_fate_data:fate_address()
            , chain_api         :: aefa_chain_api:state()
            , contracts         :: map() %% Cache for loaded contracts.
            , current_bb        :: non_neg_integer()
            , current_contract  :: void_or_address()
            , current_function  :: ?FATE_VOID | binary()
            , functions         :: map()    %% Cache for current contract.
            , gas               :: integer()
            , logs              :: [term()] %% TODO: Not used properly yet
            , memory            :: [map()] %% Stack of environments #{name => val}
            , trace             :: list()
            }).

-opaque state() :: #es{}.
-export_type([ state/0
             ]).

-spec new(non_neg_integer(), map(), aefa_chain_api:state(), map()) -> state().
new(Gas, Spec, APIState, Contracts) ->
    #es{ accumulator       = ?FATE_VOID
       , accumulator_stack = []
       , bbs               = #{}
       , call_stack        = []
       , caller            = aeb_fate_data:make_address(maps:get(caller, Spec))
       , chain_api         = APIState
       , contracts         = Contracts
       , current_bb        = 0
       , current_contract  = ?FATE_VOID
       , current_function  = ?FATE_VOID
       , functions         = #{}
       , gas               = Gas
       , logs              = []
       , memory            = []
       , trace             = []
       }.

%%%===================================================================
%%% API
%%%===================================================================

-ifdef(TEST).
add_trace(I, #es{trace = Trace} = ES) ->
    ES#es{trace = [{I, erlang:process_info(self(), reductions)}|Trace]}.
-endif.

-spec update_for_remote_call(aeb_fate_data:fate_address(), term(), state()) -> state().
update_for_remote_call(Address, ContractCode, #es{current_contract = Current} = ES) ->
    #{functions := Code} = ContractCode,
    ES#es{ functions = Code
         , current_contract = Address
         , caller = Current
         }.

%%%------------------
%%% Accumulator stack

-spec push_arguments([aeb_fate_data:fate_type()], state()) -> state().
push_arguments(Args, #es{accumulator_stack = Stack, accumulator = Acc} = ES) ->
    push_arguments(lists:reverse(Args), Acc, Stack, ES).

push_arguments([], Acc, Stack, ES) ->
    ES#es{ accumulator = Acc
         , accumulator_stack = Stack};
push_arguments([A|As], Acc, Stack, ES) ->
    push_arguments(As, A, [Acc | Stack], ES).

-spec push_return_address(state()) -> state().
push_return_address(#es{ current_bb = BB
                       , current_function = Function
                       , current_contract = Contract
                       , call_stack = Stack
                       , memory = Mem} = ES) ->
    ES#es{call_stack = [{Contract, Function, BB+1, Mem}|Stack]}.


-spec push_accumulator(aeb_fate_data:fate_type(), state()) -> state().
push_accumulator(V, #es{ accumulator = ?FATE_VOID
                       , accumulator_stack = [] } = ES) ->
    ES#es{ accumulator = V
         , accumulator_stack = []};
push_accumulator(V, #es{ accumulator = X
                       , accumulator_stack = Stack } = ES) ->
    ES#es{ accumulator = V
         , accumulator_stack = [X|Stack]}.

-spec pop_accumulator(state()) -> {aeb_fate_data:fate_type(), state()}.
pop_accumulator(#es{accumulator = X, accumulator_stack = []} = ES) ->
    {X, ES#es{accumulator = ?FATE_VOID}};
pop_accumulator(#es{accumulator = X, accumulator_stack = [V|Stack]} = ES) ->
    {X, ES#es{ accumulator = V
             , accumulator_stack = Stack
           }}.

-spec dup_accumulator(state()) -> state().
dup_accumulator(#es{accumulator = X, accumulator_stack = Stack} = ES) ->
    ES#es{ accumulator = X
         , accumulator_stack = [X|Stack]}.

-spec dup_accumulator(pos_integer(), state()) -> state().
dup_accumulator(N, #es{accumulator = X, accumulator_stack = Stack} = ES) ->
    {X1, Stack} = get_n(N, [X|Stack]),
    ES#es{ accumulator = X1
         , accumulator_stack = [X|Stack]}.

get_n(0, [X|XS]) -> {X, [X|XS]};
get_n(N, [X|XS]) ->
    {Y, List} = get_n(N-1, XS),
    {Y, [X|List]}.

-spec drop_accumulator(non_neg_integer(), state()) -> state().
drop_accumulator(0, ES) -> ES;
drop_accumulator(N, #es{accumulator_stack = [V|Stack]} = ES) ->
    drop_accumulator(N-1, ES#es{accumulator = V, accumulator_stack = Stack});
drop_accumulator(N, #es{accumulator_stack = []} = ES) ->
    drop_accumulator(N-1, ES#es{accumulator = ?FATE_VOID, accumulator_stack = []}).

%%%------------------

-spec current_bb_instructions(state()) -> list().
current_bb_instructions(#es{current_bb = BB, bbs = BBS} = ES) ->
    case maps:get(BB, BBS, void) of
        void -> aefa_fate:abort({trying_to_reach_bb, BB}, ES);
        Instructions -> Instructions
    end.

%%%------------------

-spec push_env(map(), state()) -> state().
push_env(Mem, ES) ->
    ES#es{memory = [Mem|ES#es.memory]}.

%%%------------------

-spec spend_gas(non_neg_integer(), state()) -> state().
spend_gas(X, #es{gas = Gas} = ES) ->
    ES#es{gas = Gas - X}.

%%%------------------

-spec accumulator(state()) -> void_or_fate().
accumulator(#es{accumulator = X}) ->
    X.

-spec set_accumulator(void_or_fate(), state()) -> state().
set_accumulator(X, ES) ->
    ES#es{accumulator = X}.

%%%------------------

-spec accumulator_stack(state()) -> [aeb_fate_data:fate_type()].
accumulator_stack(#es{accumulator_stack = X}) ->
    X.

-spec set_accumulator_stack([aeb_fate_data:fate_type()], state()) -> state().
set_accumulator_stack(X, ES) ->
    ES#es{accumulator_stack = X}.

%%%------------------

-spec bbs(state()) -> map().
bbs(#es{bbs = X}) ->
    X.

-spec set_bbs(map(), state()) -> state().
set_bbs(X, ES) ->
    ES#es{bbs = X}.

%%%------------------

-spec call_stack(state()) -> list().
call_stack(#es{call_stack = X}) ->
    X.

-spec set_call_stack(list(), state()) -> state().
set_call_stack(X, ES) ->
    ES#es{call_stack = X}.

%%%------------------

-spec caller(state()) -> aeb_fate_data:fate_address().
caller(#es{caller = X}) ->
    X.

-spec set_caller(aeb_fate_data:fate_address(), state()) -> state().
set_caller(X, ES) ->
    ES#es{caller = X}.

%%%------------------

-spec chain_api(state()) -> aefa_chain_api:state().
chain_api(#es{chain_api = X}) ->
    X.

-spec set_chain_api(aefa_chain_api:state(), state()) -> state().
set_chain_api(X, ES) ->
    ES#es{chain_api = X}.

%%%------------------

-spec contracts(state()) -> map().
contracts(#es{contracts = X}) ->
    X.

-spec set_contracts(map(), state()) -> state().
set_contracts(X, ES) ->
    ES#es{contracts = X}.

%%%------------------

-spec current_bb(state()) -> non_neg_integer().
current_bb(#es{current_bb = X}) ->
    X.

-spec set_current_bb(non_neg_integer(), state()) -> state().
set_current_bb(X, ES) ->
    ES#es{current_bb = X}.

%%%------------------

-spec current_contract(state()) -> aeb_fate_data:fate_address().
current_contract(#es{current_contract = X}) ->
    X.

-spec set_current_contract(aeb_fate_data:fate_address(), state()) -> state().
set_current_contract(X, ES) ->
    ES#es{current_contract = X}.

%%%------------------

-spec current_function(state()) -> binary().
current_function(#es{current_function = X}) ->
    X.

-spec set_current_function(binary(), state()) -> state().
set_current_function(X, ES) ->
    ES#es{current_function = X}.

%%%------------------

-spec functions(state()) -> map().
functions(#es{functions = X}) ->
    X.

-spec set_functions(map(), state()) -> state().
set_functions(X, ES) ->
    ES#es{functions = X}.

%%%------------------

-spec gas(state()) -> integer().
gas(#es{gas = X}) ->
    X.

-spec set_gas(integer(), state()) -> state().
set_gas(X, ES) ->
    ES#es{gas = X}.

%%%------------------

-spec logs(state()) -> list().
logs(#es{logs = X}) ->
    X.

-spec set_logs(list(), state()) -> state().
set_logs(X, ES) ->
    ES#es{logs = X}.

%%%------------------

-spec memory(state()) -> list().
memory(#es{memory = X}) ->
    X.

-spec set_memory(list(), state()) -> state().
set_memory(X, ES) ->
    ES#es{memory = X}.

%%%------------------

-spec trace(state()) -> list().
trace(#es{trace = X}) ->
    X.

-spec set_trace(list(), state()) -> state().
set_trace(X, ES) ->
    ES#es{trace = X}.


