-module(rebar_provider).

%% API
-export([create/1,
         new/2,
         do/2,
         impl/1,
         get_provider/2,
         get_target_providers/2,
         help/1,
         format/1]).

-export_type([t/0]).

-include("rebar.hrl").

%%%===================================================================
%%% Types
%%%===================================================================

-type t() :: record(provider).

-type provider_name() :: atom().

-callback init(rebar_state:t()) -> {ok, rebar_state:t()}.
-callback do(rebar_state:t()) ->  {ok, rebar_state:t()}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc create a new provider object from the specified module. The
%% module should implement the provider behaviour.
%%
%% @param ModuleName The module name.
%% @param State0 The current state of the system
-spec new(module(), rebar_state:t()) -> {ok, rebar_state:t()}.
new(ModuleName, State) when is_atom(ModuleName) ->
    case code:which(ModuleName) of
        non_existing ->
            ?ERROR("Module ~p does not exist.", [ModuleName]),
            {ok, State};
        _ ->
            ModuleName:init(State)
    end.

-spec create(list()) -> t().
create(Attrs) ->
    #provider{name=proplists:get_value(name, Attrs, undefined)
             ,provider_impl=proplists:get_value(provider_impl, Attrs, undefined)
             ,bare=proplists:get_value(bare, Attrs, false)
             ,deps=proplists:get_value(deps, Attrs, [])
             ,desc=proplists:get_value(desc, Attrs, "")
             ,short_desc=proplists:get_value(short_desc, Attrs, "")
             ,example=proplists:get_value(example, Attrs, "")
             ,opts=proplists:get_value(opts, Attrs, [])}.

%% @doc Manipulate the state of the system, that new state
%%
%% @param Provider the provider object
%% @param State the current state of the system
-spec do(Provider::t(), rebar_state:t()) -> {ok, rebar_state:t()}.
do(Provider, State) ->
    {PreHooks, PostHooks} = rebar_state:hooks(State, Provider#provider.name),
    {ok, State1} = run_hook_plugins(PreHooks, State),
    {ok, State2} = (Provider#provider.provider_impl):do(State1),
    run_hook_plugins(PostHooks, State2).

-spec run_hook_plugins([t()], rebar_state:t()) -> {ok, rebar_state:t()}.
run_hook_plugins(Hooks, State) ->
    State1 = lists:foldl(fun(Hook, StateAcc) ->
                                 {ok, StateAcc1} = rebar_provider:do(Hook, StateAcc),
                                 StateAcc1
                         end, State, Hooks),
    {ok, State1}.

%%% @doc get the name of the module that implements the provider
%%% @param Provider the provider object
-spec impl(Provider::t()) -> module().
impl(Provider) ->
    Provider#provider.name.

help(State) ->
    Providers = rebar_state:providers(State),
    Help = lists:sort([{ec_cnv:to_list(P#provider.name), P#provider.short_desc} || P <- Providers,
                                                                                   P#provider.bare =/= true]),
    Longest = lists:max([length(X) || {X, _} <- Help]),

    lists:foreach(fun({Name, ShortDesc}) ->
                          Length = length(Name),
                          Spacing = lists:duplicate(Longest - Length + 8, " "),
                          io:format("~s~s~s~n", [Name, Spacing, ShortDesc])
                  end, Help).


%% @doc print the provider module name
%%
%% @param T - The provider
%% @return An iolist describing the provider
-spec format(t()) -> iolist().
format(#provider{name=Name}) ->
    atom_to_list(Name).

get_target_providers(Target, State) ->
    Providers = rebar_state:providers(State),
    TargetProviders = lists:filter(fun(#provider{name=T}) when T =:= Target->
                                           true;
                                      (_) ->
                                           false
                                   end, Providers),
    process_deps(TargetProviders, Providers).

-spec get_provider(provider_name(), [t()]) -> t().
get_provider(ProviderName, [Provider = #provider{name = ProviderName} | _]) ->
    Provider;
get_provider(ProviderName, [_ | Rest]) ->
    get_provider(ProviderName, Rest);
get_provider(_ProviderName, _) ->
    [].

process_deps([], _Providers) ->
    [];
process_deps(TargetProviders, Providers) ->
    DepChain = lists:flatmap(fun(Provider) ->
                                     {DC, _, _} = process_deps(Provider, Providers, []),
                                     DC
                             end, TargetProviders),
    ['NONE' | Rest] =
        reorder_providers(lists:flatten([{'NONE', P#provider.name} || P <- TargetProviders] ++ DepChain)),
    Rest.

process_deps(Provider, Providers, Seen) ->
    case lists:member(Provider, Seen) of
        true ->
            {[], Providers, Seen};
        false ->
            Deps = Provider#provider.deps,
            DepList = lists:map(fun(Dep) ->
                                        {Dep, Provider#provider.name}
                                end, Deps),
            {NewDeps, _, NewSeen} =
                lists:foldl(fun(Arg, Acc) ->
                                    process_dep(Arg, Acc)
                            end,
                           {[], Providers, Seen}, Deps),
            {[DepList | NewDeps], Providers, NewSeen}
    end.

process_dep(ProviderName, {Deps, Providers, Seen}) ->
    Provider = get_provider(ProviderName, Providers),
    {NewDeps, _, NewSeen} = process_deps(Provider, Providers, [ProviderName | Seen]),
    {[Deps | NewDeps], Providers, NewSeen}.

%% @doc Reorder the providers according to thier dependency set.
reorder_providers(OProviderList) ->
    case rebar_topo:sort(OProviderList) of
        {ok, ProviderList} ->
            ProviderList;
        {error, {cycle, _}} ->
            ?ERROR("There was a cycle in the provider list. Unable to complete build!", [])
    end.