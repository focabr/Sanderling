module Backend.Main exposing
    ( State
    , backendMain
    )

import Base64
import Bytes
import Bytes.Decode
import Bytes.Encode
import CompilationInterface.ElmMake
import ElmFullstack
import EveOnline.VolatileHostInterface
import EveOnline.VolatileHostScript as VolatileHostScript
import InterfaceToFrontendClient
import Json.Decode
import Json.Encode
import Url
import Url.Parser


type alias State =
    { posixTimeMilli : Int
    , setup : SetupState
    , lastTaskIndex : Int
    , httpRequestsTasks : List { httpRequestId : String }
    , log : List LogEntry
    }


type alias SetupState =
    { volatileProcessId : Maybe String
    , lastRunScriptResult : Maybe (Result String (Maybe String))
    , eveOnlineProcessesIds : Maybe (List Int)
    }


type alias LogEntry =
    { posixTimeMilli : Int
    , message : String
    }


type Route
    = ApiRoute
    | FrontendWithInspectorRoute


routeFromUrl : Url.Url -> Maybe Route
routeFromUrl =
    Url.Parser.parse
        (Url.Parser.oneOf
            [ Url.Parser.map ApiRoute (Url.Parser.s "api")
            , Url.Parser.map FrontendWithInspectorRoute (Url.Parser.s "with-inspector")
            ]
        )


backendMain : ElmFullstack.BackendConfig State
backendMain =
    { init = ( initState, [] )
    , subscriptions = subscriptions
    }


subscriptions : State -> ElmFullstack.BackendSubs State
subscriptions _ =
    { httpRequest = updateForHttpRequestEvent
    , posixTimeIsPast = Nothing
    }


initSetup : SetupState
initSetup =
    { volatileProcessId = Nothing
    , lastRunScriptResult = Nothing
    , eveOnlineProcessesIds = Nothing
    }


maintainVolatileProcessTaskFromState : State -> ElmFullstack.BackendCmds State
maintainVolatileProcessTaskFromState state =
    if state.setup.volatileProcessId /= Nothing then
        []

    else
        [ ElmFullstack.CreateVolatileProcess
            { programCode = VolatileHostScript.setupScript
            , update =
                \createVolatileProcessResult stateBefore ->
                    case createVolatileProcessResult of
                        Err _ ->
                            ( stateBefore |> addLogEntry "Failed to create volatile process."
                            , []
                            )

                        Ok createVolatileProcessOk ->
                            ( { stateBefore | setup = { initSetup | volatileProcessId = Just createVolatileProcessOk.processId } }
                                |> addLogEntry ("Created volatile process with id '" ++ createVolatileProcessOk.processId ++ "'.")
                            , []
                            )
            }
        ]


updateForHttpRequestEvent : ElmFullstack.HttpRequestEventStruct -> State -> ( State, ElmFullstack.BackendCmds State )
updateForHttpRequestEvent httpRequestEvent stateBefore =
    let
        ( state, cmds ) =
            updateForHttpRequestEventWithoutVolatileProcessMaintenance httpRequestEvent stateBefore
    in
    ( state, cmds ++ maintainVolatileProcessTaskFromState state )


updateForHttpRequestEventWithoutVolatileProcessMaintenance : ElmFullstack.HttpRequestEventStruct -> State -> ( State, ElmFullstack.BackendCmds State )
updateForHttpRequestEventWithoutVolatileProcessMaintenance httpRequestEvent stateBefore =
    let
        respondWithFrontendHtmlDocument { enableInspector } =
            ( stateBefore
            , [ ElmFullstack.RespondToHttpRequest
                    { httpRequestId = httpRequestEvent.httpRequestId
                    , response =
                        { statusCode = 200
                        , bodyAsBase64 =
                            Just
                                (if enableInspector then
                                    CompilationInterface.ElmMake.elm_make__debug__base64____src_FrontendWeb_Main_elm

                                 else
                                    CompilationInterface.ElmMake.elm_make__base64____src_FrontendWeb_Main_elm
                                )
                        , headersToAdd = []
                        }
                    }
              ]
            )
    in
    case httpRequestEvent.request.uri |> Url.fromString |> Maybe.andThen routeFromUrl of
        Nothing ->
            respondWithFrontendHtmlDocument { enableInspector = False }

        Just FrontendWithInspectorRoute ->
            respondWithFrontendHtmlDocument { enableInspector = True }

        Just ApiRoute ->
            -- TODO: Consolidate the different branches to reduce duplication.
            case
                httpRequestEvent.request.bodyAsBase64
                    |> Maybe.map (Base64.toBytes >> Maybe.map (decodeBytesToString >> Maybe.withDefault "Failed to decode bytes to string") >> Maybe.withDefault "Failed to decode from base64")
                    |> Maybe.withDefault "Missing HTTP body"
                    |> Json.Decode.decodeString InterfaceToFrontendClient.jsonDecodeRequestFromClient
            of
                Err decodeError ->
                    let
                        httpResponse =
                            { httpRequestId = httpRequestEvent.httpRequestId
                            , response =
                                { statusCode = 400
                                , bodyAsBase64 =
                                    ("Failed to decode request: " ++ (decodeError |> Json.Decode.errorToString))
                                        |> encodeStringToBytes
                                        |> Base64.fromBytes
                                , headersToAdd = []
                                }
                            }
                    in
                    ( { stateBefore | posixTimeMilli = httpRequestEvent.posixTimeMilli }
                    , [ ElmFullstack.RespondToHttpRequest httpResponse ]
                    )

                Ok requestFromClient ->
                    case requestFromClient of
                        InterfaceToFrontendClient.ReadLogRequest ->
                            let
                                httpResponse =
                                    { httpRequestId = httpRequestEvent.httpRequestId
                                    , response =
                                        { statusCode = 200
                                        , bodyAsBase64 =
                                            -- TODO: Also transmit time of log entry.
                                            (stateBefore.log |> List.map .message |> String.join "\n")
                                                |> encodeStringToBytes
                                                |> Base64.fromBytes
                                        , headersToAdd = []
                                        }
                                    }
                            in
                            ( { stateBefore | posixTimeMilli = httpRequestEvent.posixTimeMilli }
                            , [ ElmFullstack.RespondToHttpRequest httpResponse ]
                            )

                        InterfaceToFrontendClient.RunInVolatileHostRequest runInVolatileHostRequest ->
                            case stateBefore.setup.volatileProcessId of
                                Just volatileProcessId ->
                                    let
                                        httpRequestsTasks =
                                            { httpRequestId = httpRequestEvent.httpRequestId
                                            }
                                                :: stateBefore.httpRequestsTasks

                                        requestToVolatileProcessTask =
                                            ElmFullstack.RequestToVolatileProcess
                                                { processId = volatileProcessId
                                                , request = EveOnline.VolatileHostInterface.buildRequestStringToGetResponseFromVolatileHost runInVolatileHostRequest
                                                , update =
                                                    \requestToVolatileProcessResult stateBeforeResult ->
                                                        case requestToVolatileProcessResult of
                                                            Err ElmFullstack.ProcessNotFound ->
                                                                ( { stateBeforeResult
                                                                    | setup = initSetup
                                                                  }
                                                                    |> addLogEntry "ProcessNotFound"
                                                                , []
                                                                )

                                                            Ok requestToVolatileProcessOk ->
                                                                processRequestToVolatileProcessComplete
                                                                    { httpRequestId = httpRequestEvent.httpRequestId }
                                                                    requestToVolatileProcessOk
                                                                    stateBeforeResult
                                                }
                                    in
                                    ( { stateBefore
                                        | posixTimeMilli = httpRequestEvent.posixTimeMilli
                                        , httpRequestsTasks = httpRequestsTasks
                                        , lastTaskIndex = stateBefore.lastTaskIndex + 1
                                      }
                                    , [ requestToVolatileProcessTask ]
                                    )

                                Nothing ->
                                    let
                                        httpResponse =
                                            { httpRequestId = httpRequestEvent.httpRequestId
                                            , response =
                                                { statusCode = 200
                                                , bodyAsBase64 =
                                                    (InterfaceToFrontendClient.SetupNotCompleteResponse "Volatile process not created yet." |> InterfaceToFrontendClient.jsonEncodeRunInVolatileHostResponseStructure |> Json.Encode.encode 0)
                                                        |> encodeStringToBytes
                                                        |> Base64.fromBytes
                                                , headersToAdd = []
                                                }
                                            }
                                    in
                                    ( { stateBefore | posixTimeMilli = httpRequestEvent.posixTimeMilli }
                                    , [ ElmFullstack.RespondToHttpRequest httpResponse ]
                                    )


processRequestToVolatileProcessComplete : { httpRequestId : String } -> ElmFullstack.RequestToVolatileProcessComplete -> State -> ( State, ElmFullstack.BackendCmds State )
processRequestToVolatileProcessComplete { httpRequestId } runInVolatileProcessComplete stateBefore =
    let
        httpRequestsTasks =
            stateBefore.httpRequestsTasks
                |> List.filter (.httpRequestId >> (/=) httpRequestId)

        httpResponseBody =
            runInVolatileProcessComplete
                |> InterfaceToFrontendClient.RunInVolatileHostCompleteResponse
                |> InterfaceToFrontendClient.jsonEncodeRunInVolatileHostResponseStructure
                >> Json.Encode.encode 0

        httpResponse =
            { httpRequestId = httpRequestId
            , response =
                { statusCode = 200
                , bodyAsBase64 = httpResponseBody |> encodeStringToBytes |> Base64.fromBytes
                , headersToAdd = []
                }
            }

        exceptionLogEntries =
            case runInVolatileProcessComplete.exceptionToString of
                Just exceptionToString ->
                    [ "Run in volatile process failed with exception: " ++ exceptionToString ]

                Nothing ->
                    []
    in
    ( { stateBefore | httpRequestsTasks = httpRequestsTasks }
        |> addLogEntries exceptionLogEntries
    , [ ElmFullstack.RespondToHttpRequest httpResponse ]
    )


addLogEntry : String -> State -> State
addLogEntry logMessage =
    addLogEntries [ logMessage ]


addLogEntries : List String -> State -> State
addLogEntries logMessages stateBefore =
    let
        log =
            (logMessages
                |> List.map
                    (\logMessage -> { posixTimeMilli = stateBefore.posixTimeMilli, message = logMessage })
            )
                ++ stateBefore.log
                |> List.take 10
    in
    { stateBefore | log = log }


decodeBytesToString : Bytes.Bytes -> Maybe String
decodeBytesToString bytes =
    bytes |> Bytes.Decode.decode (Bytes.Decode.string (bytes |> Bytes.width))


encodeStringToBytes : String -> Bytes.Bytes
encodeStringToBytes =
    Bytes.Encode.string >> Bytes.Encode.encode


initState : State
initState =
    { posixTimeMilli = 0
    , setup = initSetup
    , lastTaskIndex = 0
    , httpRequestsTasks = []
    , log = []
    }
