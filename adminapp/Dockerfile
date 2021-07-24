FROM python:3.7-slim
ARG version=v0.0.7
RUN apt-get update && apt-get install -y unzip curl
RUN groupadd -r -g 999 adminapp && useradd -r -g adminapp -u 999 adminapp
RUN mkdir -p /opt/adminapp/work-dir
WORKDIR /opt/adminapp/work-dir
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt
COPY index.py /opt/adminapp/work-dir/index.py
RUN --mount=type=secret,id=github_token \ 
    curl --header "Authorization: token $(cat /run/secrets/github_token)" https://github.com/StreamState/streamstate-ui-admin/releases/download/${version}/dist.zip -o dist.zip
RUN unzip dist.zip -d public
RUN apt-get uninstall -y unzip curl
RUN rm dist.zip
RUN chown -R adminapp:adminapp /opt/adminapp/work-dir
USER adminapp
CMD ["uvicorn", "--host", "0.0.0.0", "index:app"]