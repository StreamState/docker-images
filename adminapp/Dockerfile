FROM python:3.7-slim
ARG version=v0.0.8
RUN apt-get update && apt-get install -y unzip curl jq
RUN groupadd -r -g 999 adminapp && useradd -r -g adminapp -u 999 adminapp
RUN mkdir -p /opt/adminapp/work-dir
WORKDIR /opt/adminapp/work-dir
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt
COPY index.py /opt/adminapp/work-dir/index.py
RUN --mount=type=secret,id=github_token \ 
    export asset_id=$(curl -H "Accept: application/vnd.github.v3.raw" -L -J --header "Authorization: token $(cat /run/secrets/github_token)" https://api.github.com/repos/StreamState/streamstate-ui-admin/releases | jq ". | map(select(.tag_name == \"${version}\"))[0].assets | map(select(.name == \"dist.zip\"))[0].id")
RUN echo $asset_id
RUN --mount=type=secret,id=github_token \ 
    curl -H "Accept: application/vnd.github.v3.raw" -L -J --header "Authorization: token $(cat /run/secrets/github_token)" https://api.github.com/repos/StreamState/streamstate-ui-admin/releases/assets/$asset_id -o dist.zip
RUN unzip dist.zip -d public
RUN apt-get uninstall -y unzip curl jq
RUN rm dist.zip
RUN chown -R adminapp:adminapp /opt/adminapp/work-dir
USER adminapp
CMD ["uvicorn", "--host", "0.0.0.0", "index:app"]