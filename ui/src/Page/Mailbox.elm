module Page.Mailbox exposing (Model, Msg, init, load, subscriptions, update, view)

import Data.Message as Message exposing (Message)
import Data.MessageHeader as MessageHeader exposing (MessageHeader)
import Data.Session as Session exposing (Session)
import Json.Decode as Decode exposing (Decoder)
import Html exposing (..)
import Html.Attributes
    exposing
        ( class
        , classList
        , downloadAs
        , href
        , id
        , placeholder
        , property
        , target
        , type_
        , value
        )
import Html.Events exposing (..)
import Http exposing (Error)
import HttpUtil
import Json.Encode as Encode
import Ports
import Route
import Task
import Time exposing (Time)


-- MODEL


type Body
    = TextBody
    | SafeHtmlBody


type State
    = LoadingList (Maybe MessageID)
    | ShowingList MessageList (Maybe MessageID)
    | LoadingMessage MessageList MessageID
    | ShowingMessage MessageList VisibleMessage
    | Transitioning MessageList VisibleMessage MessageID


type alias MessageID =
    String


type alias MessageList =
    { headers : List MessageHeader
    , searchFilter : String
    }


type alias VisibleMessage =
    { message : Message
    , markSeenAt : Maybe Time
    }


type alias Model =
    { mailboxName : String
    , state : State
    , bodyMode : Body
    , searchInput : String
    }


init : String -> Maybe MessageID -> Model
init mailboxName selection =
    Model mailboxName (LoadingList selection) SafeHtmlBody ""


load : String -> Cmd Msg
load mailboxName =
    Cmd.batch
        [ Ports.windowTitle (mailboxName ++ " - Inbucket")
        , getList mailboxName
        ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.state of
        ShowingMessage _ { message } ->
            if message.seen then
                Sub.none
            else
                Time.every (250 * Time.millisecond) Tick

        _ ->
            Sub.none



-- UPDATE


type Msg
    = ClickMessage MessageID
    | DeleteMessage Message
    | DeleteMessageResult (Result Http.Error ())
    | ListResult (Result Http.Error (List MessageHeader))
    | MarkSeenResult (Result Http.Error ())
    | MessageResult (Result Http.Error Message)
    | MessageBody Body
    | OpenedTime Time
    | SearchInput String
    | Tick Time
    | ViewMessage MessageID


update : Session -> Msg -> Model -> ( Model, Cmd Msg, Session.Msg )
update session msg model =
    case msg of
        ClickMessage id ->
            ( updateSelected model id
            , Cmd.batch
                [ -- Update browser location
                  Route.newUrl (Route.Message model.mailboxName id)
                , getMessage model.mailboxName id
                ]
            , Session.DisableRouting
            )

        ViewMessage id ->
            ( updateSelected model id
            , getMessage model.mailboxName id
            , Session.AddRecent model.mailboxName
            )

        DeleteMessage message ->
            updateDeleteMessage model message

        DeleteMessageResult (Ok _) ->
            ( model, Cmd.none, Session.none )

        DeleteMessageResult (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        ListResult (Ok headers) ->
            case model.state of
                LoadingList selection ->
                    let
                        newModel =
                            { model | state = ShowingList (MessageList headers "") selection }
                    in
                        case selection of
                            Just id ->
                                -- Recurse to select message id.
                                update session (ViewMessage id) newModel

                            Nothing ->
                                ( newModel, Cmd.none, Session.AddRecent model.mailboxName )

                _ ->
                    ( model, Cmd.none, Session.none )

        ListResult (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MarkSeenResult (Ok _) ->
            ( model, Cmd.none, Session.none )

        MarkSeenResult (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MessageResult (Ok message) ->
            updateMessageResult model message

        MessageResult (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MessageBody bodyMode ->
            ( { model | bodyMode = bodyMode }, Cmd.none, Session.none )

        SearchInput searchInput ->
            updateSearch model searchInput

        OpenedTime time ->
            case model.state of
                ShowingMessage list visible ->
                    if visible.message.seen then
                        ( model, Cmd.none, Session.none )
                    else
                        -- Set delay to report message as seen to backend.
                        ( { model
                            | state =
                                ShowingMessage list
                                    { visible
                                        | markSeenAt = Just (time + (1.5 * Time.second))
                                    }
                          }
                        , Cmd.none
                        , Session.none
                        )

                _ ->
                    ( model, Cmd.none, Session.none )

        Tick now ->
            case model.state of
                ShowingMessage _ { message, markSeenAt } ->
                    case markSeenAt of
                        Just deadline ->
                            if now >= deadline then
                                updateMarkMessageSeen model message
                            else
                                ( model, Cmd.none, Session.none )

                        Nothing ->
                            ( model, Cmd.none, Session.none )

                _ ->
                    ( model, Cmd.none, Session.none )


updateMessageResult : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateMessageResult model message =
    let
        bodyMode =
            if message.html == "" then
                TextBody
            else
                model.bodyMode

        updateMessage list message =
            ( { model
                | state = ShowingMessage list { message = message, markSeenAt = Nothing }
                , bodyMode = bodyMode
              }
            , Task.perform OpenedTime Time.now
            , Session.none
            )
    in
        case model.state of
            LoadingList _ ->
                ( model, Cmd.none, Session.none )

            ShowingList list _ ->
                updateMessage list message

            LoadingMessage list _ ->
                updateMessage list message

            ShowingMessage list _ ->
                updateMessage list message

            Transitioning list _ _ ->
                updateMessage list message


updateSearch : Model -> String -> ( Model, Cmd Msg, Session.Msg )
updateSearch model searchInput =
    let
        updateList list =
            { list
                | searchFilter =
                    if String.length searchInput > 1 then
                        String.toLower searchInput
                    else
                        ""
            }

        updateModel state =
            ( { model | searchInput = searchInput, state = state }
            , Cmd.none
            , Session.none
            )
    in
        case model.state of
            LoadingList _ ->
                ( model, Cmd.none, Session.none )

            ShowingList list selection ->
                updateModel (ShowingList (updateList list) selection)

            LoadingMessage list id ->
                updateModel (LoadingMessage (updateList list) id)

            ShowingMessage list visible ->
                updateModel (ShowingMessage (updateList list) visible)

            Transitioning list visible id ->
                updateModel (Transitioning (updateList list) visible id)


updateSelected : Model -> MessageID -> Model
updateSelected model id =
    case model.state of
        ShowingList list _ ->
            { model | state = LoadingMessage list id }

        ShowingMessage list visible ->
            -- Use Transitioning state to prevent message flicker.
            { model | state = Transitioning list visible id }

        Transitioning list visible _ ->
            { model | state = Transitioning list visible id }

        _ ->
            model


updateDeleteMessage : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateDeleteMessage model message =
    let
        url =
            "/api/v1/mailbox/" ++ message.mailbox ++ "/" ++ message.id

        cmd =
            HttpUtil.delete url
                |> Http.send DeleteMessageResult

        filter f messageList =
            { messageList | headers = List.filter f messageList.headers }
    in
        case model.state of
            ShowingMessage list _ ->
                ( { model
                    | state = ShowingList (filter (\x -> x.id /= message.id) list) Nothing
                  }
                , cmd
                , Session.none
                )

            _ ->
                ( model, cmd, Session.none )


updateMarkMessageSeen : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateMarkMessageSeen model message =
    case model.state of
        ShowingMessage list visible ->
            let
                message =
                    visible.message

                updateSeen header =
                    if header.id == message.id then
                        { header | seen = True }
                    else
                        header

                url =
                    "/api/v1/mailbox/" ++ message.mailbox ++ "/" ++ message.id

                command =
                    -- The URL tells the API what message to update, so we only need to indicate the
                    -- desired change in the body.
                    Encode.object [ ( "seen", Encode.bool True ) ]
                        |> Http.jsonBody
                        |> HttpUtil.patch url
                        |> Http.send MarkSeenResult

                map f messageList =
                    { messageList | headers = List.map f messageList.headers }
            in
                ( { model
                    | state =
                        ShowingMessage (map updateSeen list)
                            { visible
                                | message = { message | seen = True }
                                , markSeenAt = Nothing
                            }
                  }
                , command
                , Session.None
                )

        _ ->
            ( model, Cmd.none, Session.none )


getList : String -> Cmd Msg
getList mailboxName =
    let
        url =
            "/api/v1/mailbox/" ++ mailboxName
    in
        Http.get url (Decode.list MessageHeader.decoder)
            |> Http.send ListResult


getMessage : String -> MessageID -> Cmd Msg
getMessage mailboxName id =
    let
        url =
            "/serve/m/" ++ mailboxName ++ "/" ++ id
    in
        Http.get url Message.decoder
            |> Http.send MessageResult



-- VIEW


view : Session -> Model -> Html Msg
view session model =
    div [ id "page", class "mailbox" ]
        [ aside [ id "message-list" ]
            [ div []
                [ input [ type_ "search", placeholder "search", onInput SearchInput, value model.searchInput ] [] ]
            , case model.state of
                LoadingList _ ->
                    div [] []

                ShowingList list selection ->
                    messageList list selection

                LoadingMessage list selection ->
                    messageList list (Just selection)

                ShowingMessage list visible ->
                    messageList list (Just visible.message.id)

                Transitioning list _ selection ->
                    messageList list (Just selection)
            ]
        , main_
            [ id "message" ]
            [ case model.state of
                ShowingList _ _ ->
                    text
                        ("Select a message on the left,"
                            ++ " or enter a different username into the box on upper right."
                        )

                ShowingMessage _ { message } ->
                    viewMessage message model.bodyMode

                Transitioning _ { message } _ ->
                    viewMessage message model.bodyMode

                _ ->
                    text ""
            ]
        ]


messageList : MessageList -> Maybe MessageID -> Html Msg
messageList list selected =
    div []
        (list
            |> filterMessageList
            |> List.reverse
            |> List.map (messageChip selected)
        )


messageChip : Maybe MessageID -> MessageHeader -> Html Msg
messageChip selected message =
    div
        [ classList
            [ ( "message-list-entry", True )
            , ( "selected", selected == Just message.id )
            , ( "unseen", not message.seen )
            ]
        , onClick (ClickMessage message.id)
        ]
        [ div [ class "subject" ] [ text message.subject ]
        , div [ class "from" ] [ text message.from ]
        , div [ class "date" ] [ text message.date ]
        ]


viewMessage : Message -> Body -> Html Msg
viewMessage message bodyMode =
    let
        sourceUrl message =
            "/serve/m/" ++ message.mailbox ++ "/" ++ message.id ++ "/source"
    in
        div []
            [ div [ class "button-bar" ]
                [ button [ class "danger", onClick (DeleteMessage message) ] [ text "Delete" ]
                , a
                    [ href (sourceUrl message), target "_blank" ]
                    [ button [] [ text "Source" ] ]
                ]
            , dl [ id "message-header" ]
                [ dt [] [ text "From:" ]
                , dd [] [ text message.from ]
                , dt [] [ text "To:" ]
                , dd [] (List.map text message.to)
                , dt [] [ text "Date:" ]
                , dd [] [ text message.date ]
                , dt [] [ text "Subject:" ]
                , dd [] [ text message.subject ]
                ]
            , messageBody message bodyMode
            , attachments message
            ]


messageBody : Message -> Body -> Html Msg
messageBody message bodyMode =
    let
        bodyModeTab mode label =
            a
                [ classList [ ( "active", bodyMode == mode ) ]
                , onClick (MessageBody mode)
                , href "javacript:void(0)"
                ]
                [ text label ]

        safeHtml =
            bodyModeTab SafeHtmlBody "Safe HTML"

        plainText =
            bodyModeTab TextBody "Plain Text"

        tabs =
            if message.html == "" then
                [ plainText ]
            else
                [ safeHtml, plainText ]
    in
        div [ class "tab-panel" ]
            [ nav [ class "tab-bar" ] tabs
            , article [ class "message-body" ]
                [ case bodyMode of
                    SafeHtmlBody ->
                        div [ property "innerHTML" (Encode.string message.html) ] []

                    TextBody ->
                        div [ property "innerHTML" (Encode.string message.text) ] []
                ]
            ]


attachments : Message -> Html Msg
attachments message =
    let
        baseUrl =
            "/serve/m/attach/" ++ message.mailbox ++ "/" ++ message.id ++ "/"
    in
        if List.isEmpty message.attachments then
            div [] []
        else
            table [ class "attachments well" ] (List.map (attachmentRow baseUrl) message.attachments)


attachmentRow : String -> Message.Attachment -> Html Msg
attachmentRow baseUrl attach =
    let
        url =
            baseUrl ++ attach.id ++ "/" ++ attach.fileName
    in
        tr []
            [ td []
                [ a [ href url, target "_blank" ] [ text attach.fileName ]
                , text (" (" ++ attach.contentType ++ ") ")
                ]
            , td [] [ a [ href url, downloadAs attach.fileName, class "button" ] [ text "Download" ] ]
            ]



-- UTILITY


filterMessageList : MessageList -> List MessageHeader
filterMessageList list =
    if list.searchFilter == "" then
        list.headers
    else
        let
            matches header =
                String.contains list.searchFilter (String.toLower header.subject)
                    || String.contains list.searchFilter (String.toLower header.from)
        in
            List.filter matches list.headers
