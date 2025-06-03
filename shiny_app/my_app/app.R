# Library calls
library(shiny)
library(websocket)
library(httr2)
library(DBI)
library(RSQLite)
library(jsonlite)
library(lubridate)
# Check sqlite path, otherwise create one.
db_path <- "webhook.sqlite"
if (!file.exists(db_path)) {
  con <- dbConnect(RSQLite::SQLite(), db_path)
  dbExecute(con, "CREATE TABLE webhook (id INTEGER PRIMARY KEY, url TEXT)")
  dbDisconnect(con)
}
# Main user interface or 'front-end.'
ui <- navbarPage(
  "Alpha-Strike Mailing Socket",
  tabPanel(
    "Settings",
    fluidPage(
      div(
        style = "text-align:center;",
        div(style = "display:inline-block; margin-right:10px;", textInput("webhook", strong("Your Discord Webhook URL"), value = "")),
        div(style = "display:inline-block; margin-right:10px;", actionButton("save_webhook", "Save / Update Webhook")),
        div(style = "display:inline-block; margin-right:10px;", actionButton("delete_webhook", "Delete Webhook")),
        div(style = "display:inline-block;", actionButton("send_discord_test", "Send Test Payload to Discord"))
      ),
      br(),
      verbatimTextOutput("webhook_status")
    )
  ),
  tabPanel(
    "Debugging Stream",
    fluidPage(
      div(style = "text-align:center;",
          div(style = "display:inline-block; margin-right:10px;", strong("Socket Messaging Stream"))
      ),
      br(),
      verbatimTextOutput("ws_messages")
    )
  )
)
# Convert the CCP LDAP time to UTC time for end-users.
ldap_to_utc <- function(ldap_timestamp) {
  if (is.null(ldap_timestamp) || is.na(ldap_timestamp)) return(NA)
  origin <- as.POSIXct("1601-01-01 00:00:00", tz = "UTC")
  seconds <- as.numeric(ldap_timestamp) / 1e7
  utc_time <- origin + seconds
  format(utc_time, "%Y-%m-%d %H:%M:%S UTC")
}
# Build the messages for proper output. This is for discord human readable formatting.
build_pretty_msg <- function(msg) {
  # Try catch method
  tryCatch({
    # Into the data frame that makes R a famous scripting language.
    obj <- jsonlite::fromJSON(msg, simplifyDataFrame = TRUE)
    # Make sure we aren't empty.
    if (!is.null(obj$message)) {
      # Just print the message field for simple info/error messages
      return(obj$message)
      # Otherwise, create our readable message.
    } else if (is.list(obj) && !is.null(obj$victim_name)) {
      # Get the LDAP time in UTC, otherwise we send unknown.
      time_str <- if (!is.null(obj$time_stamp)) ldap_to_utc(obj$time_stamp) else "Unknown time"
      # Human readable beauty contest from the data frame. The object 'obj' names match the json formatting.
      return(sprintf(
        "🚨 **%s** lost a **%s** in **%s** to **%s**!\nTime: `%s`",
        obj$victim_name, obj$loss_type, obj$solar_system_name, obj$killer_name, time_str
      ))
      # Otherwise, create our readable message.
    } else if (is.list(obj) && length(obj) > 0 && !is.null(obj[[1]]$victim_name)) {
      # Return
      return(paste(
        sapply(obj, function(x) {
          time_str <- if (!is.null(x$time_stamp)) ldap_to_utc(x$time_stamp) else "Unknown time"
          sprintf(
            "🚨 **%s** lost a **%s** in **%s** to **%s**!\nTime: `%s`",
            x$victim_name, x$loss_type, x$solar_system_name, x$killer_name, time_str
          )
        }),
        collapse = "\n\n"
      ))
    # Otherwise, just send it.
    } else {
      return(substr(msg, 1, 1900))
    }
    # Otherwise, send the error messages.
  }, error = function(e) substr(msg, 1, 1900))
}
# The 'back-end' which represents the Shiny server. Everything, not associated with the user interface.
server <- function(input, output, session) {
  # Make sure they set a webhook.
  status_msg <- reactiveVal("No webhook set.")
  # SQLite -----------------------------------
  # Get webhook function.
  get_webhook <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    res <- dbGetQuery(con, "SELECT url FROM webhook WHERE id = 1")
    dbDisconnect(con)
    if (nrow(res) == 1) res$url else NULL
  }
  # Set webhook function.
  set_webhook <- function(webhook) {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    if (nchar(webhook) == 0) {
      dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    } else if (is.null(get_webhook())) {
      dbExecute(con, "INSERT INTO webhook (id, url) VALUES (1, ?)", params = list(webhook))
    } else {
      dbExecute(con, "UPDATE webhook SET url = ? WHERE id = 1", params = list(webhook))
    }
    dbDisconnect(con)
  }
  # Delete webhook function.
  delete_webhook <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    dbDisconnect(con)
  }
  # Save/update event.
  observeEvent(input$save_webhook, {
    if (nzchar(input$webhook) && grepl("^https://discord.com/api/webhooks/", input$webhook)) {
      set_webhook(input$webhook)
      status_msg("Webhook saved or updated!")
      updateTextInput(session, "webhook", value = input$webhook)
    } else {
      status_msg("Invalid Discord webhook URL.")
    }
  })
  # Delete event.
  observeEvent(input$delete_webhook, {
    delete_webhook()
    updateTextInput(session, "webhook", value = "")
    status_msg("Webhook deleted.")
  })
  # Get the current webhook. Make sure they set it. Otherwise, tell the user the current webhook.
  observe({
    current <- get_webhook()
    if (!is.null(current)) {
      updateTextInput(session, "webhook", value = current)
      isolate({
        if (status_msg() %in% c("No webhook set.")) {
          status_msg(paste("Current webhook:", current))
        }
      })
    } else {
      updateTextInput(session, "webhook", value = "")
      isolate({
        if (status_msg() %in% c("Webhook saved or updated!", "Webhook deleted.", "Invalid Discord webhook URL.")) {
          # Do not overwrite the result message
        } else {
          status_msg("No webhook set.")
        }
      })
    }
  })
  # Send a status message about the webhook.
  output$webhook_status <- renderText({ status_msg() })
  # Set up our connection.
  ws_url <- "wss://api.alpha-strike.space/ws/mails"
  ws <- WebSocket$new(ws_url, autoConnect = FALSE)
  ws$connect()
  # Make sure to reconnect after 2 seconds if disruption occurs.
  ws$onClose(function(event) {
    showNotification("WebSocket disconnected, reconnecting...", type = "warning")
    invalidateLater(2000, session)
    ws$connect()
  })
  # Messages variable.
  ws_messages <- reactiveVal(character(0))
  # Recieve message, full send.
  ws$onMessage(function(event) {
    msg <- event$data
    # Store for debugging
    isolate({
      messages <- ws_messages()
      messages <- c(msg, head(messages, 9))
      ws_messages(messages)
    })
    webhook <- get_webhook()
    if (!is.null(webhook) && nzchar(webhook)) {
      pretty_msg <- build_pretty_msg(msg)
      try({
        httr2::request(webhook) |>
          httr2::req_body_json(list(content = pretty_msg)) |>
          httr2::req_perform()
      }, silent = TRUE)
    }
  })
  # Test message. Spam yourself.
  observeEvent(input$send_discord_test, {
    # Get the webhook.
    webhook <- get_webhook()
    # Not empty, send payload.
    if (!is.null(webhook) && nzchar(webhook)) {
      payload <- list(content = "Thank you for using https://frontier.alpha-strike.space/. It appears your webhook was saved and is accepting messages appropriately.")
      # Send it with try catch method.
      tryCatch({
        resp <- httr2::request(webhook) |>
          httr2::req_body_json(payload) |>
          httr2::req_perform()
        showNotification("Test payload sent to Discord! Check your channel.", type = "message")
      # Otherwise, scream failure because the webhook is incorrect or formatting improperly.
      }, error = function(e) {
        showNotification(paste("Failed to send test payload:", e$message), type = "error")
      })
    # Set your webhoook!
    } else {
      showNotification("No webhook set. Save a webhook first.", type = "error")
    }
  })
  # Send back all json messages to web display for debugging.
  output$ws_messages <- renderText({
    msgs <- rev(ws_messages())
    paste(
      lapply(msgs, function(m) {
        tryCatch(jsonlite::prettify(m), error = function(e) m)
      }),
      collapse = "\n---\n"
    )
  })
  # Make sure our websocket closes when session has ended.
  session$onSessionEnded(function() {
    ws$close()
  })
}
# Create it all right here.
shinyApp(ui, server)

