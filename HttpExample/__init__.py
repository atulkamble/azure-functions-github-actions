import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.function_name(name="HttpExample")
@app.route(route="hello", methods=[func.HttpMethod.GET, func.HttpMethod.POST])
def http_example(req: func.HttpRequest) -> func.HttpResponse:
    name = req.params.get("name") or (req.get_json().get("name") if req.method == "POST" else None)
    msg = f"Hello {name} 👋" if name else "Hello from Azure Functions!"
    return func.HttpResponse(msg, mimetype="text/plain")
