FROM python:3.7-slim
ARG version=v0.0.12
RUN apt-get update && apt-get install -y unzip
RUN groupadd -r -g 999 adminapp && useradd -r -g adminapp -u 999 adminapp
RUN mkdir -p /opt/adminapp/work-dir
WORKDIR /opt/adminapp/work-dir
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt
COPY index.py /opt/adminapp/work-dir/index.py
ADD dist.zip dist.zip
RUN unzip dist.zip -d public
RUN apt-get remove -y unzip 
RUN rm dist.zip
RUN chown -R adminapp:adminapp /opt/adminapp/work-dir
USER adminapp
CMD ["uvicorn", "--host", "0.0.0.0", "index:app"]